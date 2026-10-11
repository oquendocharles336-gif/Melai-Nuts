<?php

namespace App\Http\Controllers;

use App\Contracts\DataSource;
use App\Services\ActivityLogger;
use App\Services\Platform;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\Request;

/**
 * Sales, Products, Inventory and Cash Drawer pages, live from the Melai Nuts app's database.
 * Everything is scoped by Supabase to the linked account: owners see
 * all branches, staff only their own.
 */
class OperationsController extends Controller
{
    // Per-request (scoped) services are resolved on each use instead of being held by the controller:
    // Laravel can reuse a controller instance across requests (test client, Octane), and a held one
    // would keep a previous request's account check and query results.
    private function repo(): SupabaseRepository
    {
        return app(SupabaseRepository::class);
    }

    private function identity(): StaffIdentity
    {
        return app(StaffIdentity::class);
    }

    private function platform(): Platform
    {
        return app(Platform::class);
    }

    public function sales(Request $request, DataSource $data)
    {
        $days = in_array((int) $request->query('days'), [7, 30, 90], true) ? (int) $request->query('days') : 30;

        if ($this->identity()->isOwner()) {
            // The same function the owner's app screens read (net sales, refunds, pending refunds).
            $summary = $this->repo()->salesSummary($days);
        } else {
            // Staff: the same definition through sales_overview, limited by the database to their branch.
            $today = now('Asia/Manila')->toDateString();
            $ranges = ['today' => [$today, $today], 'week' => [now('Asia/Manila')->subDays(6)->toDateString(), $today],
                'window' => [now('Asia/Manila')->subDays($days - 1)->toDateString(), $today]];
            $this->repo()->prefetch(array_map(fn ($r) => ['salesOverview', [$r[0], $r[1], null]], array_values($ranges)));
            $o = array_map(fn ($r) => $data->salesOverview($r[0], $r[1], null), $ranges);
            $summary = $o['window'] === null ? null : $this->staffSalesSummary($days, $o);
        }

        // Owners: sales per cashier across all branches for the same window (owner-only SQL function).
        $staff = $this->identity()->isOwner() ? $this->repo()->staffOverview(now()->startOfDay()->subDays($days - 1), now()) : null;

        return view('ops.sales', ['summary' => $summary, 'days' => $days, 'isOwner' => $this->identity()->isOwner(), 'staff' => $staff]);
    }

    /** owner_sales_summary's shape, filled from three sales_overview() answers (no figure is computed here). */
    private function staffSalesSummary(int $days, array $o): array
    {
        $row = fn (?array $ov, string $id) => \App\Support\DashboardKpis::row($ov['by_branch'] ?? [], 'branch_id', $id);

        return [
            'days' => $days,
            'branches' => collect($o['window']['by_branch'] ?? [])->map(function ($w) use ($o, $row) {
                $t = $row($o['today'], $w['branch_id']);
                $wk = $row($o['week'], $w['branch_id']);

                return ['branch_id' => $w['branch_id'], 'name' => $w['branch'],
                    'today_revenue' => $t['net_sales'] ?? null, 'week_revenue' => $wk['net_sales'] ?? null, 'window_revenue' => $w['net_sales'],
                    'orders_today' => $t['orders'] ?? null, 'orders_window' => $w['orders'],
                    'window' => $w, 'pending_refund_count' => $w['pending_refund_count'] ?? null, 'pending_refund_amount' => $w['pending_refund_amount'] ?? null];
            })->values()->all(),
            'products' => collect($o['window']['by_product'] ?? [])->filter(fn ($p) => $p['product'] !== null)->map(fn ($p) => [
                'product_name' => $p['product'].(in_array($p['variant'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$p['variant']),
                'units' => $p['net_units'], 'refunded_units' => $p['refunded_units'], 'revenue' => $p['net_sales'],
                'gross_sales' => $p['gross_sales'], 'refunds' => $p['refunds']])->take(50)->values()->all(),
            'daily' => array_map(fn ($d) => $d + ['revenue' => $d['net_sales']], $o['window']['by_day'] ?? []),
            'totals' => ['window' => $o['window']['summary'] ?? null, 'pending_refunds' => $o['window']['pending_refunds'] ?? null],
        ];
    }

    public function products()
    {
        return view('ops.products', ['products' => $this->repo()->products()]);
    }

    public function toggleProduct(Request $request, string $product)
    {
        abort_unless(preg_match('/^[0-9a-f-]{36}$/i', $product), 404);
        $active = $request->boolean('active');
        $this->repo()->setProductActive($product, $active);
        ActivityLogger::log('product.active_changed', ($active ? 'Showed' : 'Hid')." product {$product} in the app", null, [
            'product_id' => $product, 'is_active' => $active, 'source' => 'supabase',
        ]);

        return back()->with('status', $active ? 'Product is now available in the app.' : 'Product is now hidden in the app.');
    }

    public function inventory(Request $request, DataSource $data)
    {
        $branches = $this->platform()->branches();
        $branchId = collect($branches)->pluck('id')->contains($request->query('branch')) ? $request->query('branch') : ($branches[0]['id'] ?? null);
        abort_if(! $branchId, 404, 'No branch is available to this account.');

        // Cached per account + branch; on a miss the six reads of this page come in ONE round trip.
        $page = \App\Support\Swr::remember("inventory:$branchId", \App\Support\Swr::fresh(), \App\Support\Swr::stale(), function () use ($data, $branches, $branchId) {
            $this->repo()->prefetch([...app(\App\Services\SharedReads::class)->stockReads(), ['products', []], ['inventory', [$branchId]], ['stockMovements', [$branchId, 50]],
                ['reorderSuggestions', [$branchId]], ['expiringBatches', [$branchId, 30]]]);

            // Every branch the account may see (owners: all) at a glance, from admin_portal_stock().
            $stock = app(\App\Services\SharedReads::class)->stock();
            $overview = collect($branches)->map(fn ($b) => [
                'id' => $b['id'], 'name' => $b['name'],
                'items' => count($stock[$b['id']] ?? []),
                'low' => collect($stock[$b['id']] ?? [])->filter(fn ($i) => $i['qty'] > 0 && $i['qty'] <= $i['reorder'])->count(),
                'out' => collect($stock[$b['id']] ?? [])->filter(fn ($i) => $i['qty'] <= 0)->count(),
                'units' => collect($stock[$b['id']] ?? [])->sum('qty'),
            ])->all();

            // Category names for the Stock page filter (product id => category), from the app's catalogue.
            try {
                $categories = collect($this->repo()->products())->mapWithKeys(fn ($p) => [$p['id'] => $p['category'] ?? null])->all();
            } catch (\Throwable) {
                $categories = [];
            }

            return [
                'overview' => $overview, 'categories' => $categories,
                'inventory' => $this->repo()->inventory($branchId),
                'movements' => $this->repo()->stockMovements($branchId, 50),
                'reorder' => $this->repo()->reorderSuggestions($branchId),
                'expiring' => $this->repo()->expiringBatches($branchId, 30),
            ];
        });

        return view('ops.inventory', $page + ['branches' => $branches, 'branchId' => $branchId]);
    }

    /**
     * Cash drawer shifts and the daily cashier summary for one day: one branch, or (owners, the
     * default for them) every branch, each read with staff_cashier_daily_summary and added up.
     */
    public function cashDrawer(Request $request)
    {
        $branches = $this->platform()->branches();
        abort_if(! $branches, 404, 'No branch is available to this account.');
        $isOwner = $this->identity()->isOwner();
        $ids = collect($branches)->pluck('id');
        $branchId = $ids->contains($request->query('branch')) ? $request->query('branch') : ($isOwner && count($branches) > 1 ? null : $ids->first());
        $date = is_string($request->query('date')) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $request->query('date'))
            ? $request->query('date') : now('Asia/Manila')->toDateString();

        $summary = $branchId ? $this->repo()->cashierDailySummary($branchId, $date) : $this->allBranchesCashSummary($branches, $date);

        return view('ops.cash-drawer', [
            'branches' => $branches, 'branchId' => $branchId, 'date' => $date, 'summary' => $summary,
            'allowAll' => $isOwner && count($branches) > 1,
        ]);
    }

    private function allBranchesCashSummary(array $branches, string $date): array
    {
        $keys = ['transaction_count', 'gross_sales', 'discounts', 'refunds', 'void_count', 'net_sales', 'cash_sales', 'non_cash_sales'];
        $totals = array_fill_keys($keys, 0);
        $cashiers = [];
        $shifts = [];
        foreach ($branches as $b) {
            $one = $this->repo()->cashierDailySummary($b['id'], $date);
            foreach ($keys as $k) {
                $totals[$k] += (float) ($one['totals'][$k] ?? 0);
            }
            foreach ($one['cashiers'] ?? [] as $c) {
                $cashiers[] = $c + ['branch_name' => $b['name']];
            }
            foreach ($one['shifts'] ?? [] as $sh) {
                $shifts[] = $sh + ['branch_name' => $b['name']];
            }
        }
        usort($shifts, fn ($a, $b) => strcmp((string) $a['opened_at'], (string) $b['opened_at']));
        usort($cashiers, fn ($a, $b) => (float) $b['net_sales'] <=> (float) $a['net_sales']);

        return ['branch_id' => null, 'date' => $date, 'totals' => $totals, 'cashiers' => $cashiers, 'shifts' => $shifts];
    }
}
