<?php

namespace App\Services;

use App\Contracts\DataSource;
use Carbon\Carbon;
use Illuminate\Support\Facades\Cache;

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
     * the Orders page, the Overview, the sidebar badges, the search and the dashboard's refund count.
     * ['orders' => allOrders() rows, 'lines' => [order id => [['name', 'qty', 'revenue'], ...]]]
     * ('lines' carries unit prices; only the app's database has them, the test fixtures do not).
     * Payments, Refunds and every action keep using the live allOrders().
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

    /** Drop the per-request cache (and the badge count) after an action changed data. */
    public function refresh(): void
    {
        $this->all = null;
        $this->range = null;
        Cache::forget($this->badgeKey());
    }

    public function find(string $orderId): ?array
    {
        return collect($this->allOrders())->firstWhere('id', $orderId);
    }

    /** Filters: status, method, branch, from, to (all optional). */
    public function filter(array $filters): array
    {
        return collect($this->allOrders())->filter(function ($o) use ($filters) {
            if (! empty($filters['status']) && $o['effectivePaymentStatus'] !== $filters['status']) {
                return false;
            }
            if (! empty($filters['method']) && $o['paymentMethod'] !== $filters['method']) {
                return false;
            }
            if (! empty($filters['branch']) && $o['branch'] !== $filters['branch']) {
                return false;
            }
            if (! empty($filters['from']) && $o['createdAt']->lt(Carbon::parse($filters['from'])->startOfDay())) {
                return false;
            }
            if (! empty($filters['to']) && $o['createdAt']->gt(Carbon::parse($filters['to'])->endOfDay())) {
                return false;
            }

            return true;
        })->values()->all();
    }

    /** Refunds queue: orders with a refund request, with the same filters plus refund status. */
    public function refundQueue(array $filters): array
    {
        return collect($this->allOrders())->filter(function ($o) use ($filters) {
            if (! $o['effectiveRefundStatus']) {
                return false;
            }
            if (! empty($filters['status']) && $o['effectiveRefundStatus'] !== $filters['status']) {
                return false;
            }
            if (! empty($filters['method']) && $o['paymentMethod'] !== $filters['method']) {
                return false;
            }
            if (! empty($filters['branch']) && $o['branch'] !== $filters['branch']) {
                return false;
            }

            return true;
        })->sortByDesc('createdAt')->values()->all();
    }

    /**
     * The "pending refunds" badge in the sidebar, shown on EVERY page. Counting needs the whole
     * order window, so the count is kept for a short time (melai.dashboard.cache_seconds) instead of
     * reloading all orders on each page. Pages that load the orders anyway (Payments, Refunds)
     * refresh it, and every refund / payment action clears it (refresh()).
     */
    public function pendingRefundsCount(): int
    {
        $count = fn () => collect($this->allOrders())->where('effectiveRefundStatus', 'requested')->count();
        $ttl = (int) config('melai.dashboard.cache_seconds', 45);
        if ($this->all !== null || $ttl <= 0) {
            $n = $count();
            if ($ttl > 0) {
                Cache::put($this->badgeKey(), $n, $ttl);
            }

            return $n;
        }

        return (int) Cache::remember($this->badgeKey(), $ttl, $count);
    }

    /** Per website login and linked app account: never shared between accounts. */
    private function badgeKey(): string
    {
        $user = auth()->user();

        return 'melai:pending-refunds:'.sha1(($user?->getAuthIdentifier() ?? '-').'|'.($user?->staff_uid ?? '-'));
    }
}
