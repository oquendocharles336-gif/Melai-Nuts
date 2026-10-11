<?php

namespace Tests\Unit;

use App\Support\DashboardKpis;
use Carbon\Carbon;
use PHPUnit\Framework\TestCase;

class DashboardKpisTest extends TestCase
{
    private function order(array $o): array
    {
        $at = Carbon::parse('2026-10-10 10:00');

        return $o + ['id' => uniqid(), 'branch' => 'b1', 'total' => 100.0, 'status' => 'completed', 'createdAt' => $at,
            'paymentStatus' => 'paid', 'paymentMethod' => 'gcash', 'paidAt' => $at, 'refundStatus' => null, 'refundAmount' => null, 'customerUid' => 'c1'];
    }

    /** A public.sales_overview() answer as the database returns it (figures already computed there). */
    private function sales(): array
    {
        return [
            'summary' => ['orders' => 3, 'gross_sales' => 650.0, 'discounts' => 20.0, 'refunds' => 140.0, 'refund_count' => 2,
                'net_sales' => 490.0, 'refund_rate' => 0.2222, 'average_order_value' => 210.0, 'net_units' => 9],
            'pending_refunds' => ['count' => 1, 'amount' => 75.5],
            'by_method' => [['method' => 'gcash', 'orders' => 2, 'gross_sales' => 450.0, 'refunds' => 100.0, 'net_sales' => 330.0],
                ['method' => 'cash', 'orders' => 1, 'gross_sales' => 200.0, 'refunds' => 40.0, 'net_sales' => 160.0]],
        ];
    }

    public function test_money_is_taken_from_the_database_as_is_never_recomputed(): void
    {
        // The order records disagree with the database on purpose (a refunded order, a pending
        // refund): only the database's figures may appear.
        $orders = [
            $this->order(['total' => 300.0]),
            $this->order(['total' => 200.0, 'paymentMethod' => 'cash', 'customerUid' => 'c2']),
            $this->order(['total' => 150.0, 'paymentStatus' => 'refunded', 'refundStatus' => 'refunded', 'refundAmount' => 150.0]),
            $this->order(['total' => 999.0, 'paymentStatus' => 'pending', 'paidAt' => null, 'status' => 'pending']),
            $this->order(['total' => 999.0, 'paymentStatus' => 'failed', 'paidAt' => null, 'status' => 'cancelled']),
            $this->order(['total' => 500.0, 'createdAt' => Carbon::parse('2026-10-01'), 'paidAt' => Carbon::parse('2026-10-01')]), // outside period
        ];
        $k = DashboardKpis::compute($orders, [], Carbon::parse('2026-10-10 00:00'), Carbon::parse('2026-10-10 23:59'), $this->sales());

        $this->assertTrue($k['sales_available']);
        $this->assertSame(650.0, $k['gross_sales']);
        $this->assertSame(20.0, $k['discounts']);
        $this->assertSame(140.0, $k['refunds']);
        $this->assertSame(2, $k['refund_count']);
        $this->assertSame(490.0, $k['net_sales']);
        $this->assertSame(0.2222, $k['refund_rate']);
        $this->assertSame(210.0, $k['average_order_value']);
        $this->assertSame(3, $k['paid_orders']);
        $this->assertSame(1, $k['pending_refund_count']);
        $this->assertSame(75.5, $k['pending_refund_amount']);
        $this->assertSame(['gcash', 'cash'], array_column($k['payment_methods'], 'method'));
        $this->assertSame(330.0, $k['payment_methods'][0]['amount'], 'per method: net of refunds');
        // Counts still come from the order records of the period.
        $this->assertSame(5, $k['orders']);
        $this->assertSame(2, $k['customers']);
        $this->assertSame(1, $k['payments_pending']);
        $this->assertSame(0, $k['payments_failed'], 'a cancelled order is not an outstanding failed payment');
        $this->assertSame(['pending' => 1, 'completed' => 3, 'cancelled' => 1], array_column($k['statuses'], 'count', 'key')); // workflow order
    }

    public function test_without_database_figures_money_is_unknown_not_zero(): void
    {
        $k = DashboardKpis::compute([$this->order([])], [], Carbon::parse('2026-10-10'), Carbon::parse('2026-10-11'), null);

        $this->assertFalse($k['sales_available']);
        foreach (['gross_sales', 'discounts', 'refunds', 'refund_count', 'net_sales', 'refund_rate', 'average_order_value', 'paid_orders',
            'pending_refund_count', 'pending_refund_amount'] as $key) {
            $this->assertNull($k[$key], "$key must be null (shown as —), never 0");
        }
        $this->assertSame([], $k['payment_methods']);
        $this->assertSame(1, $k['orders'], 'counts do not depend on the money figures');
    }

    public function test_empty_period_from_the_database_gives_zeros_and_no_average(): void
    {
        $empty = ['summary' => ['orders' => 0, 'gross_sales' => 0, 'discounts' => 0, 'refunds' => 0, 'refund_count' => 0, 'net_sales' => 0,
            'refund_rate' => null, 'average_order_value' => null], 'pending_refunds' => ['count' => 0, 'amount' => 0], 'by_method' => []];
        $k = DashboardKpis::compute([], [], Carbon::parse('2026-10-10'), Carbon::parse('2026-10-11'), $empty);

        $this->assertSame(0, $k['orders']);
        $this->assertSame(0.0, $k['gross_sales']);
        $this->assertNull($k['average_order_value']);
        $this->assertNull($k['refund_rate'], 'no sales: no rate (not 0%)');
        $this->assertSame([], $k['payment_methods']);
        $this->assertSame(0, $k['stock_items']);
    }

    public function test_row_finds_a_branch_row(): void
    {
        $rows = [['branch_id' => 'a', 'net_sales' => 1], ['branch_id' => 'b', 'net_sales' => 2]];
        $this->assertSame(2, DashboardKpis::row($rows, 'branch_id', 'b')['net_sales']);
        $this->assertNull(DashboardKpis::row($rows, 'branch_id', 'c'));
        $this->assertNull(DashboardKpis::row(null, 'branch_id', 'a'));
    }

    public function test_stock_counts_and_no_delivery_figure(): void
    {
        $stock = ['b1' => [['product' => 'A', 'qty' => 0, 'reorder' => 5, 'par' => null], ['product' => 'B', 'qty' => 3, 'reorder' => 5, 'par' => null],
            ['product' => 'C', 'qty' => 50, 'reorder' => 5, 'par' => null]]];
        $k = DashboardKpis::compute([], $stock, Carbon::now()->subDay(), Carbon::now());

        $this->assertSame(3, $k['stock_items']);
        $this->assertSame(1, $k['low_stock']);
        $this->assertSame(1, $k['out_of_stock']);
        // Deliveries are managed in the app only: the website has no delivery KPI.
        $this->assertArrayNotHasKey('deliveries_active', $k);
    }

    public function test_percent_is_null_when_the_denominator_is_zero(): void
    {
        $this->assertNull(DashboardKpis::percent(5, 0));
        $this->assertNull(DashboardKpis::percent(null, 10));
        $this->assertSame(50.0, DashboardKpis::percent(1, 2));
    }
}
