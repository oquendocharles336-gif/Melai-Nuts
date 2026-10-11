<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Http\Requests\ApproveRefundRequest;
use App\Http\Requests\RejectRefundRequest;
use App\Services\ActivityLogger;
use App\Services\HitPay\HitPayRefundService;
use App\Services\OrderQueryService;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use App\Support\ListTools;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;

/**
 * Refund queue. Every decision is made by the database
 * (admin_portal_review_refund -> staff_review_refund): it checks the branch and the
 * refunds permission, enforces the refund state machine, returns stock/points and marks
 * the payment refunded on completion, notifies the customer and writes the audit log.
 * Nothing is recorded locally and no refund is ever reported as sent unless the database or
 * HitPay confirmed it.
 */
class RefundController extends Controller
{
    // Per-request (scoped) services are resolved on each use instead of being held by the controller:
    // Laravel can reuse a controller instance across requests (test client, Octane), and a held one
    // would keep a previous request's account check and query results.
    private function orders(): OrderQueryService
    {
        return app(OrderQueryService::class);
    }

    private function platform(): Platform
    {
        return app(Platform::class);
    }

    public function index(Request $request)
    {
        $filters = $request->only(['status', 'method', 'branch']);
        $q = ListTools::query($request);
        $refunds = ListTools::paginate(ListTools::search($this->orders()->refundQueue($filters), $q, [self::class, 'searchText']), $request, 24);
        $hitpay = app(HitPayRefundService::class);
        $attempts = [];
        if ($this->platform()->isSupabase()) {
            // Latest HitPay attempt of each approved online refund (few at a time).
            foreach ($refunds as $r) {
                if (($r['effectiveRefundStatus'] ?? null) === 'approved_processing' && ! empty($r['refundId']) && ($r['paymentMethod'] ?? '') !== 'cash') {
                    try {
                        $attempts[$r['refundId']] = $this->repoAttempts($r['refundId'])[0] ?? null;
                    } catch (\Throwable $e) {
                        $attempts[$r['refundId']] = null;
                    }
                }
            }
        }

        return view('admin.refunds.index', [
            'refunds' => $refunds,
            'attempts' => $attempts,
            'hitpayReady' => $this->platform()->isSupabase() && $hitpay->configured(),
            'branches' => $this->platform()->branches(),
            'cashMethod' => $this->platform()->cashMethod(),
            'liveData' => $this->platform()->isSupabase(),
            'filters' => $filters,
            'q' => $q,
        ]);
    }

    /** CSV of every refund request matching the page's filters and search. */
    public function export(Request $request)
    {
        $q = ListTools::query($request);
        $rows = ListTools::search($this->orders()->refundQueue($request->only(['status', 'method', 'branch'])), $q, [self::class, 'searchText']);
        ActivityLogger::log('refunds.exported', 'Exported refunds ('.count($rows).' rows)', $request->user(), ['q' => $q] + $request->only(['status', 'method', 'branch']));

        return ListTools::csv('melai-refunds-'.now('Asia/Manila')->format('Y-m-d').'.csv', [
            'refund' => fn ($o) => $o['refundId'] ?? null, 'order' => fn ($o) => $o['id'], 'placed_at' => fn ($o) => $o['createdAt'],
            'branch' => fn ($o) => $o['branchName'] ?? $o['branch'], 'customer' => fn ($o) => $o['customer'], 'method' => fn ($o) => $o['paymentMethod'],
            'order_total' => fn ($o) => $o['total'], 'refund_amount' => fn ($o) => $o['refundAmount'], 'status' => fn ($o) => $o['effectiveRefundStatus'],
            'reason' => fn ($o) => $o['refundReason'] ?? null, 'completed_at' => fn ($o) => $o['refundCompletedAt'] ?? null,
        ], $rows);
    }

    /** What the search box matches: order, refund id, customer, branch, reason. */
    public static function searchText(array $o): string
    {
        return implode(' ', [$o['id'], $o['refundId'] ?? '', $o['customer'] ?? '', $o['branchName'] ?? '', $o['refundReason'] ?? '']);
    }

    public function approve(ApproveRefundRequest $request, string $orderId)
    {
        $order = $this->orders()->find($orderId);
        abort_if(! $order, 404);

        $this->guardRefundable($order);

        return $this->approveInSupabase($request, $order);
    }

    private function approveInSupabase(ApproveRefundRequest $request, array $order)
    {
        $amount = $order['refundAmount'];
        // The amount was computed by the database from the items the customer returned; it cannot be changed here.
        if ($request->filled('amount') && (float) $request->input('amount') !== (float) $amount) {
            throw ValidationException::withMessages(['amount' => 'The refund amount comes from the customer\'s request in the app (₱'.number_format($amount, 2).') and cannot be changed here.']);
        }

        $repo = app(SupabaseRepository::class);
        $isCash = $order['paymentMethod'] === 'cash';
        $repo->reviewRefund($order['refundId'], $isCash ? 'approve_cash' : 'approve', $request->input('note'));
        $this->orders()->refresh();

        ActivityLogger::log($isCash ? 'refund.approved_cash' : 'refund.approved', "Approved refund {$order['refundId']} for order {$order['id']}", null, [
            'order_id' => $order['id'], 'refund_id' => $order['refundId'], 'amount' => $amount, 'source' => 'supabase',
        ]);

        return back()->with('status', $isCash
            ? 'Cash refund of ₱'.number_format($amount, 2)." recorded for order {$order['id']}. Stock and points were returned by the app."
            : 'Refund approved for order '.$order['id'].'. Now send ₱'.number_format($amount, 2).' back: press "Send via HitPay", or refund from the HitPay dashboard and use "Mark refunded".');
    }

    /** Supabase only: the money for an approved online refund has been sent back through HitPay. */
    public function complete(Request $request, string $orderId)
    {
        abort_unless($this->platform()->isSupabase(), 404);
        $data = $request->validate(['reference' => ['required', 'string', 'min:4', 'max:120']],
            ['reference.required' => 'Enter the refund reference from HitPay.']);

        $order = $this->orders()->find($orderId);
        abort_if(! $order, 404);
        if ($order['effectiveRefundStatus'] !== 'approved_processing') {
            throw ValidationException::withMessages(['refund' => 'Only an approved refund can be marked as refunded.']);
        }
        $this->guardNotOverRefund($order);

        app(SupabaseRepository::class)->reviewRefund($order['refundId'], 'complete', $data['reference']);
        $this->orders()->refresh();
        ActivityLogger::log('refund.completed', "Marked refund {$order['refundId']} for order {$orderId} as refunded", null, [
            'order_id' => $orderId, 'refund_id' => $order['refundId'], 'reference' => $data['reference'], 'source' => 'supabase',
        ]);

        return back()->with('status', "Refund for order {$orderId} marked as refunded.");
    }

    private function repoAttempts(string $refundId): array
    {
        return app(SupabaseRepository::class)->gatewayAttempts($refundId);
    }

    /** Supabase only: send the approved online refund back through the HitPay Refund API. */
    public function sendHitpay(string $orderId, HitPayRefundService $hitpay)
    {
        abort_unless($this->platform()->isSupabase() && $hitpay->configured(), 404);
        $order = $this->orders()->find($orderId);
        abort_if(! $order || empty($order['refundId']), 404);
        if ($order['effectiveRefundStatus'] !== 'approved_processing') {
            throw ValidationException::withMessages(['refund' => 'Only an approved refund can be sent to HitPay.']);
        }

        $result = $hitpay->send($order['refundId']);
        $this->orders()->refresh();
        ActivityLogger::log('refund.hitpay_'.$result['status'], "HitPay refund for order {$orderId}: {$result['status']}", null, [
            'order_id' => $orderId, 'refund_id' => $order['refundId'], 'attempt' => $result['attempt']['attempt_id'] ?? null,
        ]);

        return back()->with(in_array($result['status'], ['succeeded', 'pending'], true) ? 'status' : 'error', $result['message']);
    }

    /** Supabase only: re-check a refund HitPay reported as still processing. */
    public function checkHitpay(Request $request, string $orderId, HitPayRefundService $hitpay)
    {
        abort_unless($this->platform()->isSupabase() && $hitpay->configured(), 404);
        $data = $request->validate(['attempt_id' => ['required', 'uuid']]);
        $order = $this->orders()->find($orderId);
        abort_if(! $order || empty($order['refundId']), 404);

        $result = $hitpay->check($order['refundId'], $data['attempt_id']);
        $this->orders()->refresh();

        return back()->with(in_array($result['status'], ['succeeded', 'pending'], true) ? 'status' : 'error', $result['message']);
    }

    /** Supabase only: close an attempt HitPay never answered, after checking the HitPay dashboard. */
    public function abandonHitpay(Request $request, string $orderId)
    {
        abort_unless($this->platform()->isSupabase(), 404);
        $data = $request->validate(['attempt_id' => ['required', 'uuid'], 'note' => ['required', 'string', 'min:5', 'max:200']]);
        app(SupabaseRepository::class)->abandonGatewayRefund($data['attempt_id'], $data['note']);
        ActivityLogger::log('refund.hitpay_abandoned', "Closed unanswered HitPay attempt for order {$orderId}", null, ['order_id' => $orderId, 'note' => $data['note']]);

        return back()->with('status', 'The unanswered attempt was closed. You can send the refund again.');
    }

    public function reject(RejectRefundRequest $request, string $orderId)
    {
        $order = $this->orders()->find($orderId);
        abort_if(! $order, 404);

        // Approved-but-unpaid refunds may still be rejected (the database allows approved -> rejected).
        if (! in_array($order['effectiveRefundStatus'], ['requested', 'approved_processing'], true)) {
            throw ValidationException::withMessages(['refund' => 'This refund request has already been processed, or there is no active request for this order.']);
        }
        app(SupabaseRepository::class)->reviewRefund($order['refundId'], 'reject', (string) $request->string('reason'));
        $this->orders()->refresh();
        ActivityLogger::log('refund.rejected', "Rejected refund {$order['refundId']} for order {$orderId}: {$request->input('reason')}", null, [
            'order_id' => $orderId, 'refund_id' => $order['refundId'], 'source' => 'supabase',
        ]);

        return back()->with('status', "Refund request for order {$orderId} rejected. The customer was told the reason.");
    }

    /** Shared checks for approve/reject: must be a genuine, single, outstanding request on a paid order. */
    private function guardRefundable(array $order): void
    {
        if ($order['effectiveRefundStatus'] !== 'requested') {
            throw ValidationException::withMessages(['refund' => 'This refund request has already been processed, or there is no active request for this order.']);
        }
        if (! in_array($order['paymentStatus'], ['paid', 'refunded'], true)) {
            throw ValidationException::withMessages(['refund' => 'Only paid orders can be refunded.']);
        }
        $this->guardNotOverRefund($order);
    }

    /**
     * Early, readable message for a refund larger than what is left to refund on the order (paid
     * minus refunds already completed, as computed by the database). The database enforces the same
     * rule itself (_validate_refund_against_paid), so this is only a friendlier error.
     */
    private function guardNotOverRefund(array $order): void
    {
        $left = $order['refundableAmount'] ?? null;
        if ($left !== null && (float) $order['refundAmount'] > $left + 0.004) {
            throw ValidationException::withMessages(['refund' => 'This refund (₱'.number_format((float) $order['refundAmount'], 2)
                .') is more than what is left to refund on order '.$order['id'].' (₱'.number_format($left, 2).').']);
        }
    }
}
