<?php

namespace App\Services\Data;

use App\Contracts\DataSource;
use App\Services\Supabase\SupabaseRepository;
use Carbon\Carbon;

/**
 * Real data from the mobile app's Supabase database, mapped into the shapes the dashboard,
 * Payments, Refunds and Loyalty pages already use. Read-only: admin actions go through
 * SupabaseRepository's action methods (Supabase functions), never through local tables.
 */
class SupabaseDataSource implements DataSource
{
    /** payments.status -> admin payment status */
    private const PAYMENT = ['success' => 'paid', 'refunded' => 'refunded', 'pending' => 'pending', 'processing' => 'pending', 'failed' => 'failed'];

    /** refund_requests.status -> admin refund status */
    private const REFUND = ['pending' => 'requested', 'approved' => 'approved_processing', 'processing' => 'approved_processing',
        'completed' => 'refunded', 'rejected' => 'rejected'];

    public function __construct(private SupabaseRepository $repo) {}

    private function date(?string $v): ?Carbon
    {
        return $v ? Carbon::parse($v)->setTimezone(config('app.timezone')) : null;
    }

    public function orders(Carbon $from, Carbon $to): array
    {
        return array_map(fn (array $o) => $this->mapOrder($o), $this->repo->orders($from, $to));
    }

    public function mapOrder(array $o): array
    {
        $pay = $o['payment'] ?? null;
        $refund = $o['refund'] ?? null;
        $payStatus = self::PAYMENT[$pay['status'] ?? 'pending'] ?? 'pending';

        return [
            'id' => $o['id'],
            'branch' => $o['branch_id'],
            'branchName' => $o['branch_name'],
            'items' => array_map(fn ($i) => $i['quantity'].'x '.$i['product_name']
                .(in_array($i['variant_label'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$i['variant_label']), $o['items'] ?? []),
            'total' => (float) $o['total'],
            'status' => $o['status'],
            'createdAt' => $this->date($o['created_at']),
            'paymentStatus' => $payStatus,
            'paymentMethod' => $pay['method'] ?? 'unknown',
            'paymentLabel' => $o['payment_label'] ?? null,
            'paymentId' => $pay['id'] ?? null,
            'paymentReference' => $pay['reference_number'] ?? null,
            // The app has no separate "paid at" column; the payment row's last update is when it was confirmed.
            'paidAt' => in_array($payStatus, ['paid', 'refunded'], true) ? $this->date($pay['updated_at'] ?? null) : null,
            'refundStatus' => $refund ? (self::REFUND[$refund['status']] ?? null) : null,
            'refundRawStatus' => $refund['status'] ?? null,
            'refundId' => $refund['id'] ?? null,
            'refundAmount' => $refund ? (float) $refund['amount'] : null,
            // The order's refund state, computed by the database (_order_refund_json): what was actually
            // refunded (completed refunds only), what is still pending, and the points reversed.
            // null on a database without migration 20261015000000 (shown as "—", never 0).
            'refundState' => $o['refund_summary']['state'] ?? null,
            'refundedAmount' => isset($o['refund_summary']) ? (float) $o['refund_summary']['refunded_amount'] : null,
            'refundedUnits' => isset($o['refund_summary']) ? (int) $o['refund_summary']['refunded_units'] : null,
            'pendingRefundAmount' => isset($o['refund_summary']) ? (float) $o['refund_summary']['pending_amount'] : null,
            'refundableAmount' => isset($o['refund_summary']['refundable_amount']) ? (float) $o['refund_summary']['refundable_amount'] : null,
            'pointsReversed' => isset($o['refund_summary']) ? (int) $o['refund_summary']['points_reversed'] : null,
            'refundCompletedAt' => $this->date($refund['completed_at'] ?? null),
            'customer' => $o['customer_name'] ?? '—', // no name on the customer's profile: shown as such, never invented
            'customerUid' => $o['customer_uid'] ?? null,
            'refundReason' => $refund ? trim($refund['reason'].(($refund['notes'] ?? '') !== '' ? ' — '.$refund['notes'] : '')) : null,
            'refundPhoto' => null, // the app does not upload refund photos
            'isPos' => (bool) ($o['is_pos'] ?? false),
            'isDelivery' => (bool) ($o['is_delivery'] ?? false),
        ];
    }

    /**
     * No par level exists in the app; 'par' is null and the dashboard uses restock thresholds instead.
     * Only variants the branch actually carries (has an inventory row for) are listed: a product a
     * branch never stocks is not "out of stock" there. Databases without migration 20261012000000
     * do not send 'carried'; then every item is kept, as before.
     */
    public function stock(): array
    {
        $out = [];
        foreach ($this->repo->stock() as $branch) {
            $items = array_filter($branch['items'] ?? [], fn ($i) => ($i['carried'] ?? true) === true);
            $out[$branch['branch_id']] = array_values(array_map(fn ($i) => [
                'product' => $i['product_name'].(in_array($i['variant_label'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$i['variant_label']),
                'qty' => (int) $i['quantity'], 'par' => null, 'reorder' => (int) $i['restock_threshold'],
            ], $items));
        }

        return $out;
    }

    public function loyalty(): array
    {
        $s = $this->repo->loyaltySummary();

        return ['members' => (int) ($s['members'] ?? 0), 'issued_month' => (int) ($s['issued_month'] ?? 0),
            'redeemed_month' => (int) ($s['redeemed_month'] ?? 0),
            // points taken back by refunds (migration 20261015000000); null on an older database
            'reversed_month' => isset($s['reversed_month']) ? (int) $s['reversed_month'] : null];
    }

    public function loyaltyMembers(): array
    {
        return array_map(fn ($m) => [
            'id' => $m['id'], 'name' => $m['name'], 'email' => $m['email'], 'cardNumber' => $m['card_number'] ?? '—',
            'tier' => null, 'pointsHistory' => [],
        ], $this->repo->loyaltyMembers(null, 1000));
    }

    public function salesOverview(string $from, string $to, ?string $branchId = null): ?array
    {
        return $this->repo->salesOverview($from, $to, $branchId);
    }

    public function pendingRefunds(): int
    {
        $from = now()->subDays(config('melai.supabase.order_window_days', 90));

        return collect($this->orders($from, now()))->where('refundStatus', 'requested')->count();
    }
}
