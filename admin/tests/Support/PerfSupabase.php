<?php

namespace Tests\Support;

use App\Support\SupabaseTimer;

/**
 * TEST-ONLY: FakeSupabase that answers every SQL function the heavy pages use, with realistic
 * amounts of data, and optionally sleeps PERF_LATENCY_MS per round trip (default 0) to simulate
 * the distance to Supabase. Every call goes through SupabaseTimer like the real gateway, so the
 * Server-Timing numbers and the per-route call counts are measured the same way.
 */
class PerfSupabase extends FakeSupabase
{
    public int $latencyMs = 0;
    public ?\Closure $override = null;

    public static function build(FakeSupabase $base, int $orders = 400): self
    {
        $f = new self;
        foreach (['branches', 'staff', 'stock', 'activity'] as $p) {
            $f->{$p} = $base->{$p};
        }
        $f->latencyMs = (int) env('PERF_LATENCY_MS', 0);
        mt_srand(11);
        $statuses = ['completed', 'completed', 'completed', 'pending', 'confirmed', 'preparing', 'outForDelivery', 'cancelled'];
        for ($i = 0; $i < $orders; $i++) {
            $at = now()->subMinutes(mt_rand(1, 60 * 24 * 85))->toIso8601String();
            $b = $i % 2 ? 'b-lb' : 'b-cal';
            $f->orders[] = [
                'id' => "ORD-$i", 'branch_id' => $b, 'branch_name' => $b === 'b-cal' ? 'Calamba Branch' : 'Los Baños Branch',
                'total' => mt_rand(150, 900), 'status' => $statuses[$i % count($statuses)], 'created_at' => $at,
                'items' => [['product_name' => 'Garlic Peanuts', 'variant_label' => 'Regular', 'quantity' => mt_rand(1, 4), 'unit_price' => 90]],
                'payment' => ['id' => "pay-$i", 'method' => 'cash', 'status' => 'success', 'reference_number' => null, 'updated_at' => $at],
                'refund' => null, 'customer_name' => 'Customer '.($i % 20), 'customer_uid' => 'c'.($i % 20), 'is_pos' => (bool) ($i % 3), 'is_delivery' => ! ($i % 4), 'payment_label' => 'Cash',
            ];
        }

        return $f;
    }

    private bool $inBatch = false;

    public function call(string $firebaseUid, string $sql, array $bindings = [], array $verified = []): mixed
    {
        if ($this->inBatch) {
            return $this->dispatch($firebaseUid, $sql, $bindings, $verified);
        }
        if (($parts = $this->splitBatch($sql, $bindings)) !== null) {
            // ONE round trip for the whole batch, like the real gateway.
            return SupabaseTimer::measure(SupabaseTimer::label($sql), function () use ($parts, $firebaseUid, $verified) {
                if ($this->latencyMs) {
                    usleep($this->latencyMs * 1000);
                }
                $this->inBatch = true;
                try {
                    $out = [];
                    foreach ($parts as [$alias, $one, $b]) {
                        $out[$alias] = $this->dispatch($firebaseUid, $one, $b, $verified);
                    }

                    return $out;
                } finally {
                    $this->inBatch = false;
                }
            });
        }

        return SupabaseTimer::measure(SupabaseTimer::label($sql), function () use ($firebaseUid, $sql, $bindings, $verified) {
            if ($this->latencyMs) {
                usleep($this->latencyMs * 1000);
            }

            return $this->dispatch($firebaseUid, $sql, $bindings, $verified);
        });
    }

    private function dispatch(string $firebaseUid, string $sql, array $bindings, array $verified): mixed
    {
        preg_match('/public\.(\w+)\(/', $sql, $m);
        $fn = $m[1] ?? 'sql';
        if ($this->override && ($r = ($this->override)($fn, $bindings)) !== null) {
            $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];

            return $r === false ? null : $r;
        }
        $answer = $this->answer($fn, $bindings);
        if ($answer !== null) {
            $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];

            return $answer;
        }

        return parent::call($firebaseUid, $sql, $bindings, $verified);
    }

    private function answer(string $fn, array $b): ?array
    {
        $items = fn ($branch) => collect(range(1, 24))->map(fn ($k) => [
            'product_id' => "p$k", 'product_name' => "Product $k", 'category_id' => null,
            'variant_id' => sprintf('00000000-0000-4000-8000-%012d', $k), 'variant_label' => 'Regular', 'sku' => "SKU$k",
            'price' => 90 + $k, 'quantity' => ($k * 7) % 60, 'restock_threshold' => 10, 'batched_quantity' => ($k * 7) % 60])->all();
        $days = fn ($from, $to) => collect(\Carbon\CarbonPeriod::create($from, $to))->map(fn ($d) => ['date' => $d->toDateString(),
            'orders' => 9, 'gross_sales' => 4200, 'discounts' => 0, 'refunds' => 0, 'net_sales' => 4200])->values()->all();

        return match ($fn) {
            'sql' => [], // branch map positions
            'staff_get_inventory' => ['branch_id' => $b[0], 'branch_name' => 'Calamba Branch', 'items' => $items($b[0]), 'batches' => []],
            'admin_portal_products' => collect(range(1, 24))->map(fn ($k) => ['id' => "p$k", 'name' => "Product $k", 'category' => 'Peanuts', 'sku' => "SKU$k",
                'unit' => null, 'price' => 90, 'is_active' => true, 'is_featured' => false, 'variants' => []])->all(),
            'admin_portal_stock_movements' => [],
            'staff_reorder_suggestions' => ['lookback_days' => 28, 'open_days' => 20, 'lead_time_days' => 7, 'safety_days' => 3, 'cover_days' => 14, 'items' => []],
            'staff_expiring_batches' => [],
            'staff_list_purchase_receipts' => [],
            'admin_portal_loyalty_summary' => ['members' => 3, 'issued_month' => 120, 'redeemed_month' => 40],
            'analytics_report' => ['summary' => ['gross_sales' => 100000, 'net_sales' => 98000, 'verified_orders' => 300], 'by_day' => $days($b[0], $b[1]), 'definitions' => []],
            default => null,
        };
    }
}
