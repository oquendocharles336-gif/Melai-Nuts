<?php

namespace App\Services;

use App\Contracts\DataSource;
use App\Services\Supabase\SupabaseRepository;
use App\Support\DashboardKpis;
use Carbon\Carbon;
use App\Support\Swr;
use Illuminate\Support\Facades\Log;

/**
 * Numbers for the redesigned Overview page and the sidebar badges.
 *
 * Money (revenue = net sales, gross, refunds, units, channels, top sellers, payment methods) comes
 * from the database's public.sales_overview(), the same figures the app shows: gross = orders with
 * a confirmed payment by order date, refunds = completed refunds on the day they completed
 * (partial ones included), net = gross - discounts - refunds; pending refunds are not deducted.
 * Counts (orders placed, pipeline, activity) come from the order records (DataSource, already
 * limited by Supabase to the branches the account may see). Nothing here is estimated or invented:
 * when a figure cannot be derived it is null and the page says so.
 *
 * Answers are cached briefly per login (melai.dashboard.cache_seconds) and keyed by
 * AdminActions::version(), which every write action bumps, so a change shows up immediately.
 */
class OverviewService
{
    public const RANGES = [7, 30, 90];

    /** App order status -> pipeline stage of the design. */
    public const STAGES = [
        'pending' => 'new', 'confirmed' => 'new',
        'preparing' => 'packing',
        'readyForPickup' => 'shipped', 'outForDelivery' => 'shipped',
        'completed' => 'delivered',
    ];

    public function __construct(private DataSource $data, private Platform $platform, private OrderQueryService $orders) {}

    // ---- Overview ------------------------------------------------------------------------------

    public function overview(int $range, ?string $branchId = null, bool $fresh = false): array
    {
        $range = in_array($range, self::RANGES, true) ? $range : 30;
        $branches = $this->platform->branches();
        $branchId = collect($branches)->pluck('id')->contains($branchId) ? $branchId : null;

        if ($fresh) {
            Swr::$force = true;
        }

        return Swr::remember("overview:$range:".now()->toDateString().":$branchId", Swr::fresh(), Swr::stale(),
            fn () => $this->buildOverview($range, $branches, $branchId));
    }

    private function buildOverview(int $range, array $branches, ?string $branchId): array
    {
        $now = now();
        $from = $now->copy()->startOfDay()->subDays($range - 1);
        $prevFrom = $from->copy()->subDays($range);
        $prevTo = $from->copy()->subMicrosecond();
        $ids = $branchId ? [$branchId] : array_column($branches, 'id');
        $period = [$from->toDateString(), $now->toDateString(), $branchId];
        $before = [$prevFrom->toDateString(), $prevTo->toDateString(), $branchId];

        // Orders (only for counts, the pipeline and recent activity): 7 and 30 days (plus the period
        // before) fit in the shared, cached 90-day order window; 90 days needs 180 days of orders and
        // reads them itself. Money comes from sales_overview for this range and the one before.
        // Everything missing comes in ONE round trip.
        $useWindow = $prevFrom->gte($this->orders->range()[0]);
        if ($this->platform->isSupabase()) {
            app(SupabaseRepository::class)->prefetch(array_merge(
                $useWindow ? $this->orders->windowReads() : [['orders', [$prevFrom, $now, null]]],
                [['salesOverview', $period], ['salesOverview', $before]],
                app(SharedReads::class)->stockReads(), [['stockMovements', [null, 15]], ['purchaseReceipts', [count($ids) === 1 ? $ids[0] : null, null]]]));
        }
        $source = $useWindow ? $this->orders->cachedOrders() : $this->data->orders($prevFrom, $now);
        $all = array_values(array_filter($source, fn ($o) => in_array($o['branch'] ?? null, $ids, true)
            && $o['createdAt'] && $o['createdAt']->gte($prevFrom) && $o['createdAt']->lte($now)));

        // MONEY: computed once by the database (public.sales_overview), the same figures as the app.
        $sales = $this->data->salesOverview(...$period);
        $prevSales = $this->data->salesOverview(...$before);
        $cur = DashboardKpis::compute($all, [], $from, $now, $sales);
        $prev = DashboardKpis::compute($all, [], $prevFrom, $prevTo, $prevSales);
        // "Compared with before" only when the period before had any sale or refund at all.
        $hasPrev = $prevSales !== null && (($prev['paid_orders'] ?? 0) > 0 || ($prev['refund_count'] ?? 0) > 0);

        // Daily series: sales_overview by_day (net sales, net units, average order value);
        // orders placed per day from the order records.
        $byDay = collect($sales['by_day'] ?? [])->keyBy('date');
        $series = [];
        for ($d = $from->copy(); $d->lte($now); $d->addDay()) {
            $key = $d->toDateString();
            $row = $byDay[$key] ?? null;
            $series[] = ['date' => $key,
                'revenue' => $row === null ? null : (float) $row['net_sales'],
                'units' => $row === null ? null : (int) $row['net_units'],
                'aov' => $row === null ? null : ($row['average_order_value'] === null ? 0 : (float) $row['average_order_value']),
                'orders' => count(array_filter($all, fn ($o) => $o['createdAt']->toDateString() === $key))];
        }

        // Channels (in-store / delivery / pickup), net of refunds.
        $labels = ['pos' => 'In-store (POS)', 'delivery' => 'Online · delivery', 'pickup' => 'Online · pickup'];
        $byChannel = collect($sales['by_channel'] ?? [])->keyBy('channel');
        $channels = $sales === null ? [] : array_values(array_map(fn ($k) => ['key' => $k, 'label' => $labels[$k],
            'amount' => (float) ($byChannel[$k]['net_sales'] ?? 0), 'orders' => (int) ($byChannel[$k]['orders'] ?? 0)], array_keys($labels)));

        // Top sellers: net units (sold - refunded); share of net product sales.
        $products = collect($sales['by_product'] ?? [])->filter(fn ($p) => ($p['product'] ?? null) !== null)
            ->sortByDesc(fn ($p) => (int) $p['net_units'])->values();
        $totalNet = $products->sum(fn ($p) => max(0, (float) $p['net_sales']));
        $top = $products->take(5)->map(fn ($p) => [
            'name' => $p['product'].(in_array($p['variant'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$p['variant']),
            'units' => (int) $p['net_units'], 'refunded_units' => (int) $p['refunded_units'], 'revenue' => (float) $p['net_sales'],
            'share' => $totalNet > 0 ? round(max(0, (float) $p['net_sales']) / $totalNet * 100, 1) : 0.0,
        ])->all();
        $maxUnits = max(1, collect($top)->max('units') ?? 1);

        // Pipeline: orders placed in the window, by stage of the app's workflow.
        $created = array_filter($all, fn ($o) => $o['createdAt']->between($from, $now));
        $pipeline = ['new' => 0, 'packing' => 0, 'shipped' => 0, 'delivered' => 0];
        foreach ($created as $o) {
            if (isset(self::STAGES[$o['status']])) {
                $pipeline[self::STAGES[$o['status']]]++;
            }
        }
        $weekAgo = $now->copy()->subDays(7);
        $returned = collect($all)->filter(fn ($o) => in_array($o['refundStatus'] ?? null, ['requested', 'approved_processing', 'refunded'], true)
            && $o['createdAt'] && $o['createdAt']->gte($weekAgo))->count();
        $cancelled = collect($created)->where('status', 'cancelled')->count();

        return [
            'range' => $range,
            'from' => $from->toDateString(), 'to' => $now->toDateString(),
            'branchId' => $branchId,
            'scope' => $branchId ? (collect($branches)->firstWhere('id', $branchId)['name'] ?? '') : (count($branches) > 1 ? 'All branches' : ($branches[0]['name'] ?? '')),
            'salesAvailable' => $sales !== null,
            'revenue' => [
                'total' => $cur['net_sales'],
                'gross' => $cur['gross_sales'], 'refunds' => $cur['refunds'], 'refundCount' => $cur['refund_count'],
                'refundRate' => $cur['refund_rate'], 'pendingRefunds' => $cur['pending_refund_amount'],
                'previous' => $hasPrev ? $prev['net_sales'] : null,
                'delta' => $hasPrev ? DashboardKpis::percent(($cur['net_sales'] ?? 0) - $prev['net_sales'], $prev['net_sales']) : null,
                // no figures (function missing): no line at all, never a line of zeros
                'series' => $sales === null ? [] : array_map(fn ($d) => ['date' => $d['date'], 'value' => $d['revenue']], $series),
            ],
            'kpis' => [
                'orders' => ['value' => $cur['orders'], 'delta' => $hasPrev ? DashboardKpis::percent($cur['orders'] - $prev['orders'], $prev['orders']) : null,
                    'spark' => array_column($series, 'orders')],
                'items' => ['value' => $cur['net_units'], 'delta' => $hasPrev ? DashboardKpis::percent(($cur['net_units'] ?? 0) - $prev['net_units'], $prev['net_units']) : null,
                    'spark' => $sales === null ? [] : array_map(fn ($d) => $d['units'] ?? 0, $series)],
                'average' => ['value' => $cur['average_order_value'],
                    'delta' => $hasPrev && $prev['average_order_value'] ? DashboardKpis::percent(($cur['average_order_value'] ?? 0) - $prev['average_order_value'], $prev['average_order_value']) : null,
                    'spark' => $sales === null ? [] : array_map(fn ($d) => $d['aov'] ?? 0, $series)],
                'low' => $this->lowStock($branches, $ids),
            ],
            'pipeline' => ['counts' => $pipeline, 'total' => array_sum($pipeline), 'returned' => $returned, 'cancelled' => $cancelled],
            'channels' => $channels,
            'top' => array_map(fn ($t) => $t + ['bar' => round($t['units'] / $maxUnits * 100)], $top),
            'topBy' => 'revenue',
            'payments' => array_map(fn ($m) => $m + ['label' => self::methodLabel($m['method'])], $cur['payment_methods']),
            'activity' => $this->activity($all, $ids),
            'updatedAt' => $now->toIso8601String(),
        ];
    }

    // ---- Sidebar badges + plan card --------------------------------------------------------------

    public function navCounts(bool $fresh = false): array
    {
        // The account check runs on every request, outside the cache.
        $branches = $this->platform->branches();
        if ($fresh) {
            Swr::$force = true;
        }

        return Swr::remember('nav:'.now()->format('Y-m'), Swr::fresh(), Swr::stale(), function () use ($branches) {
            $ids = array_column($branches, 'id');
            $now = now();
            $lastStart = $now->copy()->startOfMonth()->subMonthNoOverflow();
            $month = [$now->copy()->startOfMonth()->toDateString(), $now->toDateString(), null];
            $lastMonth = [$lastStart->toDateString(), $lastStart->copy()->endOfMonth()->toDateString(), null];
            if ($this->platform->isSupabase()) {
                app(SupabaseRepository::class)->prefetch(array_merge($this->orders->windowReads(), app(SharedReads::class)->stockReads(),
                    [['salesOverview', $month], ['salesOverview', $lastMonth]]));
            }
            $orders = array_values(array_filter($this->orders->cachedOrders(), fn ($o) => in_array($o['branch'] ?? null, $ids, true)));
            $active = collect($orders)->whereIn('status', ['pending', 'confirmed', 'preparing', 'readyForPickup', 'outForDelivery'])->count();
            $items = collect(app(SharedReads::class)->stock())->only($ids)->flatten(1);

            // Net sales this month and last month, from the database (null = unknown, shown as "—").
            $month = DashboardKpis::money($this->data->salesOverview(...$month));
            $last = DashboardKpis::money($this->data->salesOverview(...$lastMonth));
            $targetPerDay = collect($branches)->sum(fn ($b) => (float) ($b['daily_target'] ?? 0));
            $target = $targetPerDay > 0 ? round($targetPerDay * $now->daysInMonth, 2) : null;
            $goal = $target ?? (($last['net_sales'] ?? 0) > 0 ? $last['net_sales'] : null);

            return [
                'orders' => $active,
                'low' => $items->filter(fn ($i) => $i['qty'] <= $i['reorder'])->count(),
                'refunds' => collect($orders)->where('effectiveRefundStatus', 'requested')->count(),
                'month' => [
                    'label' => $now->format('F'),
                    'net' => $month['net_sales'],
                    'goal' => $goal,
                    'goalLabel' => $target !== null ? 'sales target' : 'last month',
                    'pct' => $goal && $month['net_sales'] !== null ? min(100, max(0, round($month['net_sales'] / $goal * 100))) : null,
                ],
            ];
        });
    }

    // ---- pieces ----------------------------------------------------------------------------------

    private function lowStock(array $branches, array $ids): array
    {
        $names = collect($branches)->pluck('name', 'id');
        $many = count($ids) > 1;
        $items = collect(app(SharedReads::class)->stock())->only($ids)
            ->flatMap(fn ($list, $bid) => collect($list)->map(fn ($i) => $i + ['branchName' => $names[$bid] ?? '']))
            ->filter(fn ($i) => $i['qty'] <= $i['reorder'])
            ->sortBy('qty')->values();

        return [
            'value' => $items->count(),
            'out' => $items->where('qty', '<=', 0)->count(),
            'items' => $items->take(4)->map(fn ($i) => ['name' => $i['product'].($many ? ' · '.$i['branchName'] : ''), 'qty' => (int) $i['qty']])->all(),
        ];
    }

    /** Latest orders, stock movements and supplier receipts, newest first. */
    private function activity(array $orders, array $ids): array
    {
        $rows = collect($orders)->sortByDesc(fn ($o) => $o['createdAt']?->getTimestamp() ?? 0)->take(15)->map(fn ($o) => [
            'when' => $o['createdAt']?->toIso8601String(),
            'what' => (($o['isPos'] ?? false) ? 'In-store sale ' : 'Order ').$o['id'].' · ₱'.number_format((float) $o['total'], 2),
            'area' => 'orders',
            'by' => $o['customer'] ?? '—',
            'status' => self::orderStatusLabel($o['status'] ?? ''),
            'tone' => self::orderTone($o['status'] ?? ''),
            'href' => route('orders.index', ['open' => $o['id']]),
        ])->values();

        if ($this->platform->isSupabase()) {
            $repo = app(SupabaseRepository::class);
            try {
                $rows = $rows->concat(collect($repo->stockMovements(null, 15))->filter(fn ($m) => in_array($m['branch_id'], $ids, true))->map(fn ($m) => [
                    'when' => Carbon::parse($m['created_at'])->setTimezone(config('app.timezone'))->toIso8601String(),
                    'what' => ($m['quantity_change'] > 0 ? '+' : '').$m['quantity_change'].' '.($m['product_name'] ?? 'item')
                        .(($m['variant_label'] ?? '') && $m['variant_label'] !== 'Regular' ? ' · '.$m['variant_label'] : '').' · '.$m['branch_name'],
                    'area' => 'stock',
                    'by' => $m['staff_name'] ?? '—',
                    'status' => ucfirst(str_replace('_', ' ', (string) $m['movement_type'])),
                    'tone' => $m['quantity_change'] > 0 ? 'ok' : 'neutral',
                    'href' => route('section', 'inventory'),
                ]));
            } catch (\Throwable $e) {
                Log::info('[melai] overview: stock movements unavailable: '.$e->getMessage());
            }
            try { // needs the 'inventory' permission; staff without it simply get no supplier rows
                $rows = $rows->concat(collect($repo->purchaseReceipts(count($ids) === 1 ? $ids[0] : null, null))->take(10)->map(fn ($r) => [
                    'when' => Carbon::parse($r['created_at'])->setTimezone(config('app.timezone'))->toIso8601String(),
                    'what' => 'Receipt '.$r['receipt_code'].($r['supplier_name'] ? ' from '.$r['supplier_name'] : '').' · '.$r['branch_name'],
                    'area' => 'suppliers',
                    'by' => $r['supplier_name'] ?? '—',
                    'status' => ucfirst((string) $r['status']),
                    'tone' => ['approved' => 'ok', 'draft' => 'warn', 'cancelled' => 'bad'][$r['status']] ?? 'neutral',
                    'href' => route('receipts.show', $r['id']),
                ]));
            } catch (\Throwable $e) {
                Log::info('[melai] overview: purchase receipts unavailable: '.$e->getMessage());
            }
        }

        return $rows->sortByDesc('when')->take(20)->values()->all();
    }

    public static function orderStatusLabel(string $s): string
    {
        return DashboardKpis::ORDER_STATUSES[$s] ?? ($s === 'readyForPickup' ? 'Ready for pickup' : ucfirst($s));
    }

    public static function orderTone(string $s): string
    {
        return match ($s) {
            'completed' => 'ok',
            'pending', 'confirmed' => 'info',
            'preparing', 'readyForPickup', 'outForDelivery', 'refundRequested' => 'warn',
            'cancelled', 'refunded' => 'bad',
            default => 'neutral',
        };
    }

    public static function methodLabel(string $m): string
    {
        return ['gcash' => 'GCash', 'maya' => 'Maya', 'card' => 'Card', 'cash' => 'Cash', 'cod' => 'Cash on delivery'][$m] ?? ucfirst($m);
    }
}
