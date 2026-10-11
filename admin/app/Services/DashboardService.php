<?php

namespace App\Services;

use App\Contracts\DataSource;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;
use App\Support\DashboardKpis;
use App\Support\SalesCalculator;
use Carbon\CarbonInterface;

/**
 * The dashboard, from the Melai Nuts app's real database.
 *
 * Supabase itself decides what the signed-in account may see (acting as its verified Firebase
 * UID): an OWNER gets every branch, a staff member only their own branch. On top of that:
 *  - owners can narrow the page to one branch (?branch=<id>; "All branches" by default); a
 *    branch the account may not see is ignored, so staff can never widen their view by URL;
 *  - owners also get every staff account (owner_staff_overview): role, branch, status, POS sales
 *    per cashier, shifts, open drawers and last activity; staff never call it.
 *
 * Every money figure (gross, discounts, refunds, net, refund rate, pending refunds, per branch and
 * per payment method) comes from public.sales_overview(), the database function the app's figures
 * use too; this class never adds or subtracts money itself.
 *
 * Database answers are cached for a short time (melai.dashboard.cache_seconds, default 45 s)
 * per app account, so the minute-by-minute live refresh does not re-run every query. The
 * account's status is still checked with Supabase on every request (Platform::branches), and
 * ?fresh=1 skips the cache. Nothing is ever cached across accounts.
 */
class DashboardService
{
    public function __construct(
        private DataSource $data,
        private Platform $platform,
        private StaffIdentity $identity,
    ) {}

    public function build(string $period, ?string $branchId = null, bool $fresh = false): array
    {
        $now = now();
        $from = match ($period) { 'week' => $now->copy()->startOfWeek(), 'month' => $now->copy()->startOfMonth(), default => $now->copy()->startOfDay() };

        // Checked with Supabase on EVERY request, cache or not: the account must still be active, and
        // only branches it may see are accepted (a deactivated account is signed out right here).
        $allBranches = $this->platform->branches();
        $branchId = collect($allBranches)->pluck('id')->contains($branchId) ? $branchId : null;
        $isOwner = $this->isOwner();
        if ($fresh) {
            \App\Support\Swr::$force = true;
        }

        // Whole page, cached per website login + app account, period (and its day), branch and data
        // version; a change made through the website invalidates it at once (AdminActions::version()).
        return \App\Support\Swr::remember("dashboard:$period:{$from->toDateString()}:$branchId", \App\Support\Swr::fresh(), \App\Support\Swr::stale(),
            fn () => $this->compute($period, $from, $now, $allBranches, $branchId, $isOwner));
    }

    private function compute(string $period, CarbonInterface $from, CarbonInterface $now, array $allBranches, ?string $branchId, bool $isOwner): array
    {
        $days = max(1, (int) $from->diffInDays($now->copy()->startOfDay()) + 1); // target grows with elapsed days
        $branches = $branchId ? array_values(array_filter($allBranches, fn ($b) => $b['id'] === $branchId)) : $allBranches;
        $ids = array_column($branches, 'id');
        $live = $this->platform->isSupabase();

        $fromDate = $from->toDateString();
        $today = $now->toDateString();

        // SPEED: every read this page needs, in ONE round trip (each still runs as this account).
        if ($live) {
            app(SupabaseRepository::class)->prefetch(array_merge([
                ['orders', [$from, $now, null]], ['loyaltySummary', []],
                ['salesOverview', [$fromDate, $today, $branchId]],
            ], $period === 'today' ? [] : [['salesOverview', [$today, $today, $branchId]]],
                $isOwner ? [['staffOverview', [$from, $now, $branchId]]] : [], app(SharedReads::class)->stockReads()));
        }

        // Money: computed by the database for exactly this period and scope.
        $salesPeriod = $this->data->salesOverview($fromDate, $today, $branchId);
        $salesToday = $period === 'today' ? $salesPeriod : $this->data->salesOverview($today, $today, $branchId);

        $orders = $this->onlyBranches($this->data->orders($from, $now), 'branch', $ids);
        $stockByBranch = array_intersect_key(app(SharedReads::class)->stock(), array_flip($ids));
        $loyalty = $this->data->loyalty();
        $staff = $isOwner && $live ? app(SupabaseRepository::class)->staffOverview($from, $now, $branchId) : null;

        $sales = collect($branches)->map(function ($b) use ($orders, $from, $days, $salesPeriod) {
            // The branch's row of sales_overview (null when the figures are unavailable: shown as "—").
            $row = $salesPeriod === null ? null : (DashboardKpis::row($salesPeriod['by_branch'] ?? [], 'branch_id', $b['id'])
                ?? ['net_sales' => 0, 'gross_sales' => 0, 'refunds' => 0, 'refund_count' => 0, 'orders' => 0, 'pending_refund_amount' => 0]);
            $net = $row === null ? null : (float) $row['net_sales'];
            // No target configured -> no rating (nothing is compared against an invented number).
            $target = $b['daily_target'] ? $b['daily_target'] * $days : null;
            $own = array_filter($orders, fn ($o) => $o['branch'] === $b['id']);

            return ['id' => $b['id'], 'name' => $b['name'], 'net' => $net, 'target' => $target,
                'pct' => $target && $net !== null ? round($net / $target * 100) : null,
                'status' => $target && $net !== null ? SalesCalculator::status($net, $target) : 'none',
                'gross' => $row === null ? null : (float) $row['gross_sales'],
                'refunds' => $row === null ? null : (float) $row['refunds'],
                'refund_count' => $row === null ? null : (int) $row['refund_count'],
                'pending_refund_amount' => $row === null ? null : (float) ($row['pending_refund_amount'] ?? 0),
                'orders' => count(array_filter($own, fn ($o) => $o['createdAt'] && $o['createdAt']->gte($from))),
                'paid_orders' => $row === null ? null : (int) $row['orders']];
        })->all();

        $kpis = DashboardKpis::compute($orders, $stockByBranch, $from, $now, $salesPeriod);

        return [
            'period' => $period, 'from' => $from, 'to' => $now, 'sales' => $sales,
            'kpis' => $kpis,
            'today' => $period === 'today' ? $kpis : DashboardKpis::compute($orders, $stockByBranch, $now->copy()->startOfDay(), $now, $salesToday),
            'maxPct' => max(100, collect($sales)->whereNotNull('pct')->max('pct') ?? 0),
            'stock' => $this->stock($branches, $stockByBranch),
            'branches' => $branches, 'allBranches' => $allBranches, 'branchId' => $branchId,
            'pendingRefunds' => $kpis['pending_refund_count'], 'pendingRefundAmount' => $kpis['pending_refund_amount'], 'loyalty' => $loyalty,
            'isOwner' => $isOwner,
            'topBranches' => count($branches) > 1 && $salesPeriod !== null ? collect($sales)->sortByDesc('net')->take(5)->values()->all() : [],
            'staff' => $staff,
            'staffSummary' => $staff === null ? null : $this->staffSummary($staff),
            // false only while migration 20261013000000 is missing: activity is unknown, shown as "—".
            'staffActivity' => $staff !== null && ! collect($staff)->contains('activity_unavailable', true),
            'topStaff' => $staff === null ? [] : collect($staff)->filter(fn ($s) => (float) $s['pos_sales'] > 0)
                ->sortByDesc(fn ($s) => (float) $s['pos_net_sales'])->take(5)->values()->all(),
            'liveData' => $this->platform->isSupabase(),
        ];
    }

    private function isOwner(): bool
    {
        // Owner rights come only from the app's staff registry (Supabase), never from the website role.
        return $this->platform->isSupabase() ? $this->identity->isOwner() : (bool) auth()->user()?->isAdmin();
    }

    private function onlyBranches(array $rows, string $field, array $ids): array
    {
        return array_values(array_filter($rows, fn ($r) => in_array($r[$field] ?? null, $ids, true)));
    }

    private function staffSummary(array $staff): array
    {
        $c = collect($staff);

        if ($c->contains('activity_unavailable', true)) {
            return ['accounts' => $c->count(), 'active' => $c->where('account_status', 'active')->count(),
                'owners' => $c->where('role', 'owner')->count(), 'open_shifts' => null, 'pos_transactions' => null, 'pos_net_sales' => null];
        }

        return [
            'accounts' => $c->count(),
            'active' => $c->where('account_status', 'active')->count(),
            'owners' => $c->where('role', 'owner')->count(),
            'open_shifts' => $c->where('open_shift', true)->count(),
            'pos_transactions' => (int) $c->sum('pos_transactions'),
            'pos_net_sales' => round((float) $c->sum(fn ($s) => (float) $s['pos_net_sales']), 2),
        ];
    }

    private function stock(array $branches, array $all): array
    {
        $cfg = config('melai.stock');
        $out = collect($branches)->map(function ($b) use ($cfg, $all) {
            $items = collect($all[$b['id']] ?? []);
            // Test fixtures have a par level per product. The app has none, only a restock threshold,
            // so there the ratio is the share of products above their threshold.
            // A branch with no stock records has no ratio at all (shown as "No stock records"), not 0%.
            $ratio = $items->isEmpty() ? null : ($items->contains(fn ($i) => $i['par'] === null)
                ? $items->filter(fn ($i) => $i['qty'] > $i['reorder'])->count() / $items->count()
                : ($items->sum('par') ? $items->sum('qty') / $items->sum('par') : 0));
            return ['name' => $b['name'], 'pct' => $ratio === null ? null : round($ratio * 100), 'ratio' => $ratio,
                'status' => $ratio === null ? 'none' : ($ratio < $cfg['low_below'] ? 'low' : ($ratio >= $cfg['plenty_from'] ? 'plenty' : 'normal')),
                'lowItems' => $items->filter(fn ($i) => $i['qty'] <= $i['reorder'])->values()->all(), 'lowest' => false];
        })->all();

        $withData = collect($out)->whereNotNull('ratio');
        $min = $withData->min('ratio');
        return array_map(fn ($s) => $s['ratio'] !== null && $s['ratio'] === $min && $withData->count() > 1 ? [...$s, 'lowest' => true] : $s, $out);
    }
}
