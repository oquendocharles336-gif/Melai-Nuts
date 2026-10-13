<?php

namespace App\Http\Controllers;

use App\Services\ActivityLogger;
use App\Services\Platform;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;
use Carbon\Carbon;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * Reports, CSV export and the sales forecast.
 *
 * Every number comes from the SQL functions in
 * supabase/migrations/20261010020000_analytics_forecasting.sql, which also decide who may see
 * what (owner: all branches; staff: own branch and only with the 'view_reports' permission).
 */
class ReportsController extends Controller
{
    /** The money columns every sales CSV carries, in this order (the same keys as the screen). */
    private const MONEY = ['gross_sales', 'discounts', 'refunds', 'refund_count', 'net_sales', 'refund_rate'];

    /**
     * CSV sections: report key => [file label, columns]. Every row comes straight from
     * analytics_report() (the same call the page shows), so a CSV equals the screen.
     */
    private const CSV = [
        'by_day' => ['daily-sales', ['date', 'orders', ...self::MONEY, 'units', 'refunded_units', 'net_units', 'delivery_fees']],
        'by_branch' => ['sales-by-branch', ['branch', 'orders', ...self::MONEY, 'pending_refund_count', 'pending_refund_amount']],
        'by_payment_method' => ['payment-methods', ['method', 'orders', 'amount', ...self::MONEY]],
        'by_category' => ['sales-by-category', ['category', 'gross_units', 'refunded_units', 'units', ...self::MONEY]],
        'by_product' => ['sales-by-product', ['product', 'variant', 'gross_units', 'refunded_units', 'units', 'orders', ...self::MONEY]],
        'top_products' => ['best-sellers', ['product', 'variant', 'gross_units', 'refunded_units', 'units', 'gross_sales', 'refunds', 'net_sales']],
        'by_cashier' => ['sales-by-cashier', ['staff_name', 'channel', 'orders', ...self::MONEY, 'voids']],
        'slow_movers' => ['slow-movers', ['product', 'variant', 'in_stock', 'units_sold']],
        'drivers' => ['driver-performance', ['driver', 'runs', 'delivered', 'failed', 'success_rate', 'avg_minutes_pickup_to_delivered']],
        // Owners only (owner_staff_overview): POS sales per cashier / staff account.
        'by_staff' => ['sales-by-staff', ['full_name', 'email', 'role', 'branch_name', 'account_status', 'pos_transactions', 'pos_gross_sales', 'pos_discounts', 'pos_sales', 'pos_refunds', 'pos_refund_count', 'pos_net_sales', 'pos_refund_rate', 'shifts_opened', 'last_activity_at']],
    ];

    /** Report section a CSV key reads (by_cashier is the report's by_staff list). */
    private const SOURCE = ['by_cashier' => 'by_staff'];

    /** Owner only: every staff account's activity for the report's days (Asia/Manila), one branch or all. */
    private function staff(string $from, string $to, ?string $branchId): ?array
    {
        if (! $this->identity()->isOwner()) {
            return null;
        }

        return $this->repo()->staffOverview(Carbon::parse($from, 'Asia/Manila')->startOfDay(), Carbon::parse($to, 'Asia/Manila')->addDay()->startOfDay(), $branchId);
    }

    /** @return array{0: string, 1: string, 2: ?string} [from, to, branchId] */
    private function filters(Request $request): array
    {
        $today = now('Asia/Manila')->toDateString();
        $valid = fn ($v) => is_string($v) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $v) && strtotime($v) !== false;
        $to = $valid($request->query('to')) ? $request->query('to') : $today;
        $from = $valid($request->query('from')) ? $request->query('from') : Carbon::parse($to)->subDays(29)->toDateString();

        $branchIds = collect($this->platform()->branches())->pluck('id');
        $branch = $request->query('branch');
        $branchId = $branchIds->contains($branch) ? $branch : null;
        if (! $this->identity()->isOwner()) {
            $branchId = $branchIds->first(); // staff: always their own branch
        }

        return [$from, $to, $branchId];
    }

    public function index(Request $request)
    {
        [$from, $to, $branchId] = $this->filters($request); // account + branch check, every request
        $isOwner = $this->identity()->isOwner();

        // The same report for the equally long period right before, for "compared with before".
        $days = Carbon::parse($from)->diffInDays(Carbon::parse($to)) + 1;
        $prevTo = Carbon::parse($from)->subDay();
        $prevFrom = $prevTo->copy()->subDays($days - 1)->toDateString();

        // Cached per account, dates and branch (reports cover whole days: longer fresh time). On a miss
        // the current report, the previous one and the staff list come in ONE round trip.
        $data = \App\Support\Swr::remember("reports:$from:$to:$branchId", (int) config('melai.cache.reports_seconds', 120), \App\Support\Swr::stale(),
            function () use ($from, $to, $branchId, $prevFrom, $prevTo, $isOwner) {
                $this->repo()->prefetch(array_merge(
                    [['analyticsReport', [$from, $to, $branchId]], ['analyticsReport', [$prevFrom, $prevTo->toDateString(), $branchId]]],
                    $isOwner ? [['staffOverview', [Carbon::parse($from, 'Asia/Manila')->startOfDay(), Carbon::parse($to, 'Asia/Manila')->addDay()->startOfDay(), $branchId]]] : []));
                // Optional: if it cannot be read the page simply shows no comparison (nothing is guessed).
                try {
                    $previous = $this->repo()->analyticsReport($prevFrom, $prevTo->toDateString(), $branchId);
                } catch (\Throwable $e) {
                    $previous = null;
                }

                return ['previous' => $previous, 'report' => $this->repo()->analyticsReport($from, $to, $branchId), 'staff' => $this->staff($from, $to, $branchId)];
            });

        return view('ops.reports', $data + [
            'from' => $from, 'to' => $to, 'branchId' => $branchId,
            'branches' => $this->platform()->branches(), 'isOwner' => $isOwner,
            'csv' => collect(self::CSV)->when(! $isOwner, fn ($c) => $c->except('by_staff'))->map(fn ($c) => $c[0])->all(),
        ]);
    }

    public function export(Request $request): StreamedResponse
    {
        $section = $request->query('section', 'by_day');
        abort_unless($section === 'summary' || array_key_exists($section, self::CSV), 404);
        [$from, $to, $branchId] = $this->filters($request);
        $report = $this->repo()->analyticsReport($from, $to, $branchId);

        if ($section === 'summary') {
            $label = 'summary';
            $columns = ['metric', 'value'];
            // Nested figures (pending_refunds.count, pending_payments.amount, ...) as their own lines.
            $rows = collect(\Illuminate\Support\Arr::dot($report['summary'] ?? []))->map(fn ($v, $k) => ['metric' => $k, 'value' => $v])->values()->all();
        } elseif ($section === 'by_staff') {
            abort_unless($this->identity()->isOwner(), 403);
            [$label, $columns] = self::CSV[$section];
            $rows = $this->staff($from, $to, $branchId) ?? [];
        } else {
            [$label, $columns] = self::CSV[$section];
            $rows = $report[self::SOURCE[$section] ?? $section] ?? [];
            if ($section === 'by_cashier') {
                $rows = array_map(fn ($r) => $r + ['staff_name' => $r['staff_name'] ?? 'Online orders'], $rows);
            }
        }

        ActivityLogger::log('report.exported', "Exported {$label} report ({$from} to {$to})", null, [
            'section' => $section, 'from' => $from, 'to' => $to, 'branch_id' => $branchId, 'rows' => count($rows),
        ]);

        $file = "melai-{$label}-{$from}-to-{$to}.csv";

        return response()->streamDownload(function () use ($rows, $columns) {
            $out = fopen('php://output', 'w');
            fwrite($out, "\xEF\xBB\xBF"); // UTF-8 BOM so Excel shows ₱ and ñ correctly
            fputcsv($out, $columns);
            foreach ($rows as $row) {
                fputcsv($out, array_map(fn ($c) => self::cell($row[$c] ?? ''), $columns));
            }
            fclose($out);
        }, $file, ['Content-Type' => 'text/csv; charset=UTF-8']);
    }

    /** Neutralise spreadsheet formulas in exported text (CSV injection). */
    private static function cell(mixed $v): string
    {
        $s = is_bool($v) ? ($v ? 'true' : 'false') : (string) $v;

        return preg_match('/^[=+\-@\t\r]/', $s) && ! is_numeric($s) ? "'".$s : $s;
    }

    public function forecast(Request $request)
    {
        $branches = $this->platform()->branches();
        $branchIds = collect($branches)->pluck('id');
        $branchId = $branchIds->contains($request->query('branch')) ? $request->query('branch') : $branchIds->first();
        abort_if(! $branchId, 404, 'No branch is available to this account.');

        $products = collect($this->repo()->products());
        $variants = $products->flatMap(fn ($p) => collect($p['variants'] ?? [])->map(fn ($v) => [
            'id' => $v['id'], 'label' => $p['name'].(in_array($v['label'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$v['label']),
        ]))->sortBy('label')->values();
        $variantId = $variants->pluck('id')->contains($request->query('variant')) ? $request->query('variant') : null;
        $metric = $request->query('metric') === 'revenue' ? 'revenue' : 'units';
        $granularity = $request->query('granularity') === 'week' ? 'week' : 'day';
        $maxHorizon = $granularity === 'day' ? 90 : 26;
        $horizon = max(1, min($maxHorizon, (int) ($request->query('horizon') ?: ($granularity === 'day' ? 14 : 4))));
        $valid = fn ($v) => is_string($v) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $v);
        $trainFrom = $valid($request->query('train_from')) ? $request->query('train_from') : null;
        $trainTo = $valid($request->query('train_to')) ? $request->query('train_to') : null;

        $params = compact('branchId', 'variantId', 'metric', 'granularity', 'horizon', 'trainFrom', 'trainTo');
        $result = $request->query('run') ? $this->repo()->salesForecast($branchId, $variantId, $metric, $granularity, $trainFrom, $trainTo, $horizon, null) : null;

        return view('ops.forecast', ['branches' => $branches, 'variants' => $variants, 'result' => $result] + $params);
    }

    public function saveForecast(Request $request)
    {
        $data = $request->validate([
            'branch' => ['required', 'uuid'], 'variant' => ['nullable', 'uuid'],
            'metric' => ['required', 'in:units,revenue'], 'granularity' => ['required', 'in:day,week'],
            'horizon' => ['required', 'integer', 'min:1', 'max:90'],
            'train_from' => ['nullable', 'date_format:Y-m-d'], 'train_to' => ['nullable', 'date_format:Y-m-d'],
        ]);
        $result = $this->repo()->salesForecast($data['branch'], $data['variant'] ?? null, $data['metric'], $data['granularity'],
            $data['train_from'] ?? null, $data['train_to'] ?? null, (int) $data['horizon'], null, true);
        if (($result['status'] ?? '') !== 'ok' || empty($result['run_id'])) {
            return back()->with('error', $result['message'] ?? 'Not enough sales history to save a forecast.');
        }
        ActivityLogger::log('forecast.saved', 'Saved a sales forecast', null, ['run_id' => $result['run_id']] + $data);

        return redirect()->route('reports.forecast.run', $result['run_id'])->with('status', 'Forecast saved. Come back later to compare it with actual sales.');
    }

    public function forecastRun(string $run)
    {
        abort_unless(preg_match('/^[0-9a-f-]{36}$/i', $run), 404);

        return view('ops.forecast-run', ['run' => $this->repo()->forecastAccuracy($run)]);
    }
}
