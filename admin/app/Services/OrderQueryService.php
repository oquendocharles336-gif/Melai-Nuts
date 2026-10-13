<?php

namespace App\Services;

use App\Contracts\DataSource;
use Carbon\Carbon;

/**
 * Orders for the Payments and Refunds pages, read from the Melai Nuts app's database
 * (DataSource). Every admin action is written to that database itself, so there is no local
 * copy to merge: the "effective" fields are simply the database's values (the key names are
 * kept because the views use them).
 */
class OrderQueryService
{
    private ?array $all = null;

    public function __construct(private DataSource $data) {}

    private function windowDays(): int
    {
        return (int) config('melai.supabase.order_window_days', 90);
    }

    /** [from, to] of the order window, fixed once per request so a batched prefetch matches it exactly. */
    private ?array $range = null;

    public function range(): array
    {
        return $this->range ??= [now()->subDays($this->windowDays()), now()];
    }

    /** All orders in the window (config melai.supabase.order_window_days, default 90 days), live. */
    public function allOrders(): array
    {
        [$from, $to] = $this->range();

        return $this->all ??= array_map(fn ($o) => $o + [
            'effectivePaymentStatus' => $o['paymentStatus'],
            'effectiveRefundStatus' => $o['refundStatus'],
            'refundAmountRequested' => $o['refundAmount'],
        ], $this->data->orders($from, $to));
    }

    /**
     * The same window, from the per-account stale-while-revalidate cache (App\Support\Swr), shared by
     * every list page (Orders, Payments, Refunds, Overview, sidebar badges, search, dashboard).
     * ['orders' => allOrders() rows, 'lines' => [order id => [['name', 'qty', 'revenue'], ...]]]
     * ('lines' carries unit prices; only the app's database has them, the test fixtures do not).
     * SPEED: the 90-day window is the heaviest read (~2 MB); it is loaded once and shared. It is
     * dropped after any change on this website and whenever the live pulse sees a change in the app
     * (OverviewController::pulse). Actions (find()) still read live, and the database re-checks them.
     */
    public function cachedWindow(): array
    {
        return \App\Support\Swr::remember('orders-window', \App\Support\Swr::fresh(), \App\Support\Swr::stale(), function () {
            $orders = $this->allOrders();
            $lines = [];
            if (app(Platform::class)->isSupabase()) {
                [$from, $to] = $this->range();
                // Same arguments as the DataSource call above: answered from the request memo, no round trip.
                foreach (app(\App\Services\Supabase\SupabaseRepository::class)->orders($from, $to) as $o) {
                    $lines[$o['id']] = array_map(fn ($i) => [
                        'name' => $i['product_name'].(in_array($i['variant_label'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$i['variant_label']),
                        'qty' => (int) ($i['quantity'] ?? 0),
                        'revenue' => isset($i['unit_price']) ? round((int) ($i['quantity'] ?? 0) * (float) $i['unit_price'], 2) : null,
                    ], $o['items'] ?? []);
                }
            }

            return ['orders' => $orders, 'lines' => $lines];
        });
    }

    public function cachedOrders(): array
    {
        return $this->cachedWindow()['orders'];
    }

    /** Reads to add to a batched prefetch when the cached window is missing (empty when it is cached). */
    public function windowReads(): array
    {
        return \App\Support\Swr::has('orders-window') ? [] : [['orders', $this->range()]];
    }

    /** Drop the per-request cache after an action changed data. */
    public function refresh(): void
    {
        $this->all = null;
        $this->range = null;
    }

    public function find(string $orderId): ?array
    {
        return collect($this->allOrders())->firstWhere('id', $orderId);
    }

    /** Filters: status (payment), method, branch, from, to (all optional). */
    public function filter(array $filters): array
    {
        return array_values(array_filter($this->cachedOrders(),
            fn ($o) => $this->matches($o, $filters, $o['effectivePaymentStatus'])));
    }

    /** Refunds queue: orders with a refund request, with the same filters (status = refund status). */
    public function refundQueue(array $filters): array
    {
        return collect($this->cachedOrders())
            ->filter(fn ($o) => $o['effectiveRefundStatus'] && $this->matches($o, $filters, $o['effectiveRefundStatus']))
            ->sortByDesc('createdAt')->values()->all();
    }

    /** One rule for both lists: every filter that is set must match. */
    private function matches(array $o, array $filters, ?string $status): bool
    {
        return (empty($filters['status']) || $status === $filters['status'])
            && (empty($filters['method']) || $o['paymentMethod'] === $filters['method'])
            && (empty($filters['branch']) || $o['branch'] === $filters['branch'])
            && (empty($filters['from']) || ! $o['createdAt']->lt(Carbon::parse($filters['from'])->startOfDay()))
            && (empty($filters['to']) || ! $o['createdAt']->gt(Carbon::parse($filters['to'])->endOfDay()));
    }
}
