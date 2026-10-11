<?php

namespace App\Contracts;

use Carbon\Carbon;

/**
 * Everything the dashboard reads from the mobile app's data.
 * Order shape: id, branch (branch id), items[], total, status, createdAt, paymentStatus, paymentMethod,
 *              paidAt, refundStatus, refundAmount, customer, refundReason, refundPhoto (Carbon dates).
 */
interface DataSource
{
    public function orders(Carbon $from, Carbon $to): array;
    /** [branchId => [['product'=>, 'qty'=>, 'par'=>, 'reorder'=>], ...]] */
    public function stock(): array;
    /** ['members'=>int, 'issued_month'=>int, 'redeemed_month'=>int] */
    public function loyalty(): array;
    /**
     * Loyalty members with their Firestore-side points history (before any local admin adjustments).
     * [['id','name','email','cardNumber','tier','pointsHistory'=>[['orderId','type','points','at'(Carbon)], ...]]]
     * type: earned|redeemed|refunded
     */
    public function loyaltyMembers(): array;
    public function pendingRefunds(): int;

    /**
     * Sales figures for [from, to] (Y-m-d, Asia/Manila days), computed by the database
     * (public.sales_overview): ['summary' => [gross_sales, discounts, refunds, refund_count, net_sales,
     * refund_rate, average_order_value, orders, ...], 'pending_refunds' => [count, amount], 'by_day',
     * 'by_branch', 'by_method', 'by_channel', 'by_product', 'by_staff' (null without view_reports)].
     * null when the figures cannot be read (pages show "—").
     */
    public function salesOverview(string $from, string $to, ?string $branchId = null): ?array;
}
