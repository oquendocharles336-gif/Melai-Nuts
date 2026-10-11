<?php

namespace App\Support;

use Carbon\Carbon;

/**
 * Headline numbers for the dashboard.
 *
 * MONEY comes only from the database (public.sales_overview, migration 20261015000000), the same
 * function and definition the app's screens use:
 *  - gross sales = subtotal of orders with a successful payment, by order date (Asia/Manila);
 *  - refunds = completed refunds (partial ones included), by the day they completed;
 *  - net sales = gross - discounts - refunds; refund rate = refunds / (gross - discounts);
 *  - pending refunds (requested / approved / processing) are shown apart, never deducted.
 * Nothing is added up or subtracted here: when the figures are missing they are null ("—").
 *
 * COUNTS (orders placed, statuses, customers, unpaid / failed payments) come from the order
 * records of the period (order date), plus stock.
 */
class DashboardKpis
{
    /** Order statuses used by the app (orders.status), in workflow order. */
    public const ORDER_STATUSES = [
        'pending' => 'Pending', 'confirmed' => 'Confirmed', 'preparing' => 'Preparing', 'outForDelivery' => 'Out for delivery',
        'completed' => 'Completed', 'refundRequested' => 'Refund requested', 'refunded' => 'Refunded', 'cancelled' => 'Cancelled',
    ];

    /** @param  ?array  $sales  public.sales_overview() for the same period and scope, or null when unavailable */
    public static function compute(array $orders, array $stockByBranch, Carbon $from, Carbon $to, ?array $sales = null): array
    {
        $inPeriod = fn (?Carbon $at) => $at && $at->gte($from) && $at->lte($to);
        $created = array_values(array_filter($orders, fn ($o) => $inPeriod($o['createdAt'] ?? null)));

        $statusCounts = [];
        foreach ($created as $o) {
            $statusCounts[$o['status']] = ($statusCounts[$o['status']] ?? 0) + 1;
        }
        $statuses = [];
        foreach (self::ORDER_STATUSES as $key => $label) {
            if (isset($statusCounts[$key])) {
                $statuses[] = ['key' => $key, 'label' => $label, 'count' => $statusCounts[$key]];
            }
        }
        foreach (array_diff_key($statusCounts, self::ORDER_STATUSES) as $key => $count) { // any status added later
            $statuses[] = ['key' => $key, 'label' => ucfirst((string) $key), 'count' => $count];
        }

        $payment = ['pending' => 0, 'failed' => 0];
        foreach ($created as $o) {
            if (isset($payment[$o['paymentStatus']]) && ($o['status'] ?? '') !== 'cancelled') {
                $payment[$o['paymentStatus']]++;
            }
        }

        $items = collect($stockByBranch)->flatten(1);

        return [
            'orders' => count($created),
            'customers' => count(array_unique(array_filter(array_map(fn ($o) => $o['customerUid'] ?? null, $created)))),
            'statuses' => $statuses,
            'payments_pending' => $payment['pending'],
            'payments_failed' => $payment['failed'],
            'stock_items' => $items->count(),
            'low_stock' => $items->filter(fn ($i) => $i['qty'] > 0 && $i['qty'] <= $i['reorder'])->count(),
            'out_of_stock' => $items->filter(fn ($i) => $i['qty'] <= 0)->count(),
        ] + self::money($sales);
    }

    /** The money keys, read as they are from public.sales_overview() (null = unknown, never 0). */
    public static function money(?array $sales): array
    {
        $s = is_array($sales['summary'] ?? null) ? $sales['summary'] : null;
        $num = fn (string $k) => $s !== null && isset($s[$k]) ? round((float) $s[$k], 2) : null;
        $int = fn (?array $a, string $k) => $a !== null && isset($a[$k]) ? (int) $a[$k] : null;
        $pending = is_array($sales['pending_refunds'] ?? null) ? $sales['pending_refunds'] : null;

        return [
            'sales_available' => $s !== null,
            'paid_orders' => $int($s, 'orders'),
            'gross_sales' => $num('gross_sales'),
            'discounts' => $num('discounts'),
            'refunds' => $num('refunds'),
            'refund_count' => $int($s, 'refund_count'),
            'net_sales' => $num('net_sales'),
            'refund_rate' => $s !== null && isset($s['refund_rate']) ? (float) $s['refund_rate'] : null,
            'average_order_value' => $num('average_order_value'),
            'net_units' => $int($s, 'net_units'),
            'pending_refund_count' => $int($pending, 'count'),
            'pending_refund_amount' => $pending !== null && isset($pending['amount']) ? round((float) $pending['amount'], 2) : null,
            'payment_methods' => array_values(array_map(fn ($m) => [
                'method' => $m['method'] ?? 'unknown', 'orders' => (int) ($m['orders'] ?? 0),
                'gross' => (float) ($m['gross_sales'] ?? 0), 'refunds' => (float) ($m['refunds'] ?? 0),
                'amount' => (float) ($m['net_sales'] ?? 0), // net of refunds
            ], is_array($sales['by_method'] ?? null) ? $sales['by_method'] : [])),
        ];
    }

    /** One row of by_branch / by_day / ... as the same keys (null when the row is missing). */
    public static function row(?array $rows, string $key, string $value): ?array
    {
        foreach ($rows ?? [] as $r) {
            if (($r[$key] ?? null) === $value) {
                return $r;
            }
        }

        return null;
    }

    /** a ÷ b as a percentage, or null when b is zero (never a made-up 0% or 100%). */
    public static function percent(float|int|null $part, float|int|null $whole): ?float
    {
        return $part !== null && $whole !== null && $whole > 0 ? round($part / $whole * 100, 1) : null;
    }
}
