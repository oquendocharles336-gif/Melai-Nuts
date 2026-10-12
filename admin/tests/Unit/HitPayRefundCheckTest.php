<?php

namespace Tests\Unit;

use App\Services\HitPay\HitPayRefundService;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

/**
 * Re-checking a pending HitPay refund must never close the attempt as failed unless HitPay says
 * the refund itself failed: a closed (failed) attempt unlocks "Send via HitPay" again, while HitPay
 * may already have sent the money (double refund).
 */
class HitPayRefundCheckTest extends TestCase
{
    /** In-memory stand-in for the two database calls check() makes. */
    private function repo(): SupabaseRepository
    {
        return new class extends SupabaseRepository {
            public array $attempt = ['attempt_id' => 'att-1', 'refund_id' => 'RFD-1', 'status' => 'pending',
                'gateway_refund_id' => 'hp-rf-1', 'amount' => 150];
            public array $finished = [];

            public function __construct() {}

            public function gatewayAttempts(string $refundId): array
            {
                return $refundId === $this->attempt['refund_id'] ? [$this->attempt] : [];
            }

            public function finishGatewayRefund(string $attemptId, string $status, ?string $gatewayRefundId, ?string $error): array
            {
                $this->finished[] = compact('attemptId', 'status', 'gatewayRefundId', 'error');
                $this->attempt['status'] = $status;

                return $this->attempt;
            }
        };
    }

    protected function setUp(): void
    {
        parent::setUp();
        config(['services.hitpay.api_key' => 'test-key', 'services.hitpay.env' => 'sandbox']);
    }

    public static function notAnAnswerAboutTheRefund(): array
    {
        return [
            '404 not found' => [404, ['message' => 'Not found']],
            '429 rate limited' => [429, ['message' => 'Too many requests']],
            '500 server error' => [500, ['message' => 'oops']],
            '401 bad key' => [401, ['message' => 'Unauthenticated', 'status' => 'failed']],
        ];
    }

    #[\PHPUnit\Framework\Attributes\DataProvider('notAnAnswerAboutTheRefund')]
    public function test_a_non_2xx_check_leaves_the_attempt_pending(int $http, array $body): void
    {
        Http::fake(['*/v1/refund/hp-rf-1' => Http::response($body, $http)]);
        $repo = $this->repo();

        $result = (new HitPayRefundService($repo))->check('RFD-1', 'att-1');

        $this->assertSame('unknown', $result['status']);
        $this->assertSame([], $repo->finished, 'the attempt must not be closed');
        $this->assertSame('pending', $repo->attempt['status']);
    }

    public function test_an_explicit_failed_refund_status_closes_the_attempt(): void
    {
        Http::fake(['*/v1/refund/hp-rf-1' => Http::response(['id' => 'hp-rf-1', 'status' => 'failed'], 200)]);
        $repo = $this->repo();

        $result = (new HitPayRefundService($repo))->check('RFD-1', 'att-1');

        $this->assertSame('failed', $result['status']);
        $this->assertSame('failed', $repo->finished[0]['status'] ?? null);
    }

    public function test_a_succeeded_refund_completes_the_attempt(): void
    {
        Http::fake(['*/v1/refund/hp-rf-1' => Http::response(['id' => 'hp-rf-1', 'status' => 'succeeded'], 200)]);
        $repo = $this->repo();

        $result = (new HitPayRefundService($repo))->check('RFD-1', 'att-1');

        $this->assertSame('succeeded', $result['status']);
        $this->assertSame(['attemptId' => 'att-1', 'status' => 'succeeded', 'gatewayRefundId' => 'hp-rf-1', 'error' => null], $repo->finished[0]);
    }

    public function test_send_and_check_map_a_4xx_differently(): void
    {
        $this->assertSame('failed', HitPayRefundService::sendOutcome(404, ['message' => 'No such payment'])['status']);
        $this->assertSame(['status' => 'unknown'], HitPayRefundService::checkOutcome(404, ['message' => 'No such refund']));
        $this->assertSame(['status' => 'unknown'], HitPayRefundService::checkOutcome(200, []));
    }
}
