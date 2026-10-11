<?php

namespace App\Http\Controllers\Admin;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Http\Controllers\Controller;
use App\Services\ActivityLogger;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use Carbon\Carbon;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * Owner: profit by product option and inventory valuation
 * (supabase/migrations/20261024000000_owner_reports.sql). Both use each option's CURRENT cost
 * (product_variant_costs); options without a cost are shown as "Not set", never as zero cost.
 * CSV download, and "Print / Save as PDF" through the browser's print dialog.
 */
class ProfitReportController extends Controller
{
    private const CSV = [
        'profit' => ['profit-by-product', ['product', 'variant', 'net_units', 'net_sales', 'unit_cost', 'cogs', 'profit', 'margin_percent']],
        'valuation' => ['inventory-valuation', ['branch', 'product', 'variant', 'quantity', 'unit_cost', 'value']],
    ];

    public function __construct(private SupabaseRepository $repo) {}

    /** @return array{0: string, 1: string, 2: ?string} */
    private function filters(Request $request): array
    {
        $today = now('Asia/Manila')->toDateString();
        $valid = fn ($v) => is_string($v) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $v) && strtotime($v) !== false;
        $to = $valid($request->query('to')) ? $request->query('to') : $today;
        $from = $valid($request->query('from')) ? $request->query('from') : Carbon::parse($to)->subDays(29)->toDateString();
        $branch = $request->query('branch');
        $branchId = collect(app(Platform::class)->branches())->pluck('id')->contains($branch) ? $branch : null;

        return [$from, $to, $branchId];
    }

    public function index(Request $request)
    {
        abort_unless($request->user()->isAdmin(), 403);
        [$from, $to, $branchId] = $this->filters($request);
        $profit = $valuation = null;
        $error = null;
        try {
            $profit = $this->repo->profitReport($from, $to, $branchId);
            $valuation = $this->repo->inventoryValuation($branchId);
        } catch (BackendActionException|BackendUnavailableException $e) {
            $error = $e->getMessage();
        }

        return view('admin.profit.index', [
            'profit' => $profit, 'valuation' => $valuation, 'loadError' => $error,
            'from' => $from, 'to' => $to, 'branchId' => $branchId,
            'branches' => app(Platform::class)->branches(), 'liveData' => true,
        ]);
    }

    public function export(Request $request, string $section): StreamedResponse
    {
        abort_unless($request->user()->isAdmin(), 403);
        abort_unless(array_key_exists($section, self::CSV), 404);
        [$from, $to, $branchId] = $this->filters($request);
        [$label, $columns] = self::CSV[$section];
        $data = $section === 'profit' ? $this->repo->profitReport($from, $to, $branchId) : $this->repo->inventoryValuation($branchId);
        $rows = $data['rows'] ?? [];

        ActivityLogger::log('report.exported', "Exported {$label} ({$from} to {$to})", $request->user(),
            ['section' => $section, 'from' => $from, 'to' => $to, 'branch_id' => $branchId, 'rows' => count($rows)]);
        $file = $section === 'profit' ? "melai-{$label}-{$from}-to-{$to}.csv" : "melai-{$label}-".now('Asia/Manila')->toDateString().'.csv';

        return response()->streamDownload(function () use ($rows, $columns, $data) {
            $out = fopen('php://output', 'w');
            fwrite($out, "\xEF\xBB\xBF");
            fputcsv($out, ['# cost basis: '.($data['cost_basis'] ?? 'current cost')]);
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
        $s = $v === null ? '' : (string) $v;

        return preg_match('/^[=+\-@\t\r]/', $s) && ! is_numeric($s) ? "'".$s : $s;
    }
}
