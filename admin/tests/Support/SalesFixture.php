<?php

namespace Tests\Support;

/**
 * TEST-ONLY: builds a public.sales_overview()-shaped answer from fixture rows, so the fake data
 * sources can answer it. The real figures are computed by the database (migration
 * 20261015000000_refunds_in_analytics.sql) and checked in supabase/tests/refunds_analytics_test.sql
 * and the Supabase integration tests; this only gives the pages something of the right shape.
 *
 * $rows: [['branch' => id, 'day' => 'Y-m-d', 'paid' => bool, 'gross' => float, 'refund' => float,
 *          'refund_day' => 'Y-m-d'|null, 'pending_refund' => float, 'method' => str, 'channel' => str]]
 */
final class SalesFixture
{
    public static function overview(array $rows, string $from, string $to, array $branches): array
    {
        $in = fn (?string $d) => $d !== null && $d >= $from && $d <= $to;
        $money = function (array $sales, array $refunds) {
            $g = round(array_sum(array_column($sales, 'gross')), 2);
            $r = round(array_sum(array_column($refunds, 'refund')), 2);

            return ['orders' => count($sales), 'gross_sales' => $g, 'discounts' => 0.0, 'refunds' => $r, 'refund_count' => count($refunds),
                'net_sales' => round($g - $r, 2), 'delivery_fees' => 0.0, 'revenue' => round($g - $r, 2),
                'refund_rate' => $g > 0 ? round($r / $g, 4) : null, 'average_order_value' => count($sales) ? round($g / count($sales), 2) : null];
        };
        $sales = array_values(array_filter($rows, fn ($o) => $o['paid'] && $in($o['day'])));
        $refunds = array_values(array_filter($rows, fn ($o) => ($o['refund'] ?? 0) > 0 && $in($o['refund_day'] ?? null)));
        $group = function (string $key, array $keys) use ($sales, $refunds, $money) {
            $out = [];
            foreach ($keys as $k) {
                $out[] = [$key => $k] + $money(array_filter($sales, fn ($o) => $o[$key] === $k), array_filter($refunds, fn ($o) => $o[$key] === $k));
            }

            return $out;
        };
        $days = [];
        for ($d = $from; $d <= $to; $d = date('Y-m-d', strtotime($d.' +1 day'))) {
            $days[] = ['date' => $d, 'units' => 0, 'refunded_units' => 0, 'net_units' => 0]
                + $money(array_filter($sales, fn ($o) => $o['day'] === $d), array_filter($refunds, fn ($o) => $o['refund_day'] === $d));
        }
        $pending = array_values(array_filter($rows, fn ($o) => ($o['pending_refund'] ?? 0) > 0));
        $branchRows = [];
        foreach ($branches as $b) {
            $branchRows[] = ['branch_id' => $b['id'], 'branch' => $b['name']]
                + $money(array_filter($sales, fn ($o) => $o['branch'] === $b['id']), array_filter($refunds, fn ($o) => $o['branch'] === $b['id']))
                + ['voids' => 0, 'pending_refund_count' => count(array_filter($pending, fn ($o) => $o['branch'] === $b['id'])),
                    'pending_refund_amount' => round(array_sum(array_column(array_filter($pending, fn ($o) => $o['branch'] === $b['id']), 'pending_refund')), 2)];
        }

        return [
            'from' => $from, 'to' => $to,
            'summary' => $money($sales, $refunds) + ['voids' => 0, 'units' => 0, 'refunded_units' => 0, 'net_units' => 0],
            'pending_refunds' => ['count' => count($pending), 'amount' => round(array_sum(array_column($pending, 'pending_refund')), 2)],
            'by_day' => $days,
            'by_branch' => $branchRows,
            'by_method' => array_map(fn ($m) => $m + ['amount_paid' => $m['gross_sales']],
                $group('method', array_values(array_unique(array_column($sales, 'method'))))),
            'by_channel' => $group('channel', ['delivery', 'pickup', 'pos']),
            'by_product' => [],
            'by_staff' => null,
        ];
    }
}
