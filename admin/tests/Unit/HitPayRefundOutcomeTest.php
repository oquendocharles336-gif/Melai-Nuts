<?php

namespace Tests\Unit;

use App\Services\HitPay\HitPayRefundService;
use PHPUnit\Framework\TestCase;

/** Same mapping as supabase/functions/hitpay-refund (outcomeOf). */
class HitPayRefundOutcomeTest extends TestCase
{
    public function test_success_pending_failed_unknown(): void
    {
        $this->assertSame(['status' => 'succeeded', 'refund_id' => 'rf1'], HitPayRefundService::outcome(200, ['id' => 'rf1', 'status' => 'succeeded']));
        $this->assertSame(['status' => 'pending', 'refund_id' => 'rf2'], HitPayRefundService::outcome(201, ['id' => 'rf2', 'status' => 'pending']));
        $this->assertSame('failed', HitPayRefundService::outcome(200, ['id' => 'rf3', 'status' => 'failed'])['status']);
        $this->assertSame(['status' => 'failed', 'error' => 'Amount exceeds'], HitPayRefundService::outcome(422, ['message' => 'Amount exceeds']));
        $this->assertSame('failed', HitPayRefundService::outcome(401, null)['status']);
        // A server error or an answer without an id: we do NOT know whether money moved.
        $this->assertSame(['status' => 'unknown'], HitPayRefundService::outcome(500, ['message' => 'oops']));
        $this->assertSame(['status' => 'unknown'], HitPayRefundService::outcome(200, ['status' => 'succeeded']));
    }
}
