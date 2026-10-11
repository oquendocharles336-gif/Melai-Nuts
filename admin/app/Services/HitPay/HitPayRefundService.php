<?php

namespace App\Services\HitPay;

use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * Sends an approved online refund back through the HitPay Refund API.
 *
 *   staff_begin_gateway_refund  (database: approved? HitPay payment? nothing in flight?)
 *   POST {base}/v1/refund {payment_id, amount}    (amount + payment id come from the database)
 *   staff_finish_gateway_refund (succeeded -> refund completed by the existing triggers)
 *
 * A timeout or HitPay 5xx leaves the attempt "sending": the database then refuses a second
 * send until someone checks the HitPay dashboard (no double refunds). Same logic as the
 * supabase/functions/hitpay-refund Edge Function used by the app.
 */
class HitPayRefundService
{
    public function __construct(private SupabaseRepository $repo) {}

    public function configured(): bool
    {
        return filled(config('services.hitpay.api_key'));
    }

    private function base(): string
    {
        return config('services.hitpay.env') === 'live' ? 'https://api.hit-pay.com' : 'https://api.sandbox.hit-pay.com';
    }

    private function http()
    {
        return Http::withHeaders(['X-BUSINESS-API-KEY' => (string) config('services.hitpay.api_key'), 'X-Requested-With' => 'XMLHttpRequest'])
            ->acceptJson()->timeout(max(5, (int) config('services.hitpay.timeout', 25)));
    }

    /** @return array{status: string, message: string, attempt?: array} status: succeeded|pending|failed|unknown */
    public function send(string $refundId): array
    {
        $attempt = $this->repo->beginGatewayRefund($refundId);   // throws a readable error if not allowed

        try {
            $res = $this->http()->post($this->base().'/v1/refund', [
                'payment_id' => $attempt['gateway_payment_id'],
                'amount' => (float) $attempt['amount'],
            ]);
        } catch (ConnectionException $e) {
            Log::error('[hitpay] refund: no answer', ['refund' => $refundId, 'error' => $e->getMessage()]);

            return ['status' => 'unknown', 'attempt' => $attempt,
                'message' => 'HitPay did not answer. The refund may or may not have been sent: check the HitPay dashboard before trying again.'];
        }

        return $this->record($attempt['attempt_id'], self::outcome($res->status(), $res->json()), $attempt);
    }

    /** Re-checks a pending refund (GET /v1/refund/{id}). */
    public function check(string $refundId, string $attemptId): array
    {
        $attempt = collect($this->repo->gatewayAttempts($refundId))->firstWhere('attempt_id', $attemptId);
        if (! $attempt || $attempt['status'] !== 'pending' || empty($attempt['gateway_refund_id'])) {
            return ['status' => 'unknown', 'message' => 'There is no pending HitPay refund to check.'];
        }
        try {
            $res = $this->http()->get($this->base().'/v1/refund/'.rawurlencode($attempt['gateway_refund_id']));
        } catch (ConnectionException) {
            return ['status' => 'unknown', 'message' => 'HitPay did not answer. Try again in a moment.'];
        }
        $o = self::outcome($res->status(), $res->json());
        $o['refund_id'] ??= $attempt['gateway_refund_id'];

        return $this->record($attemptId, $o, $attempt);
    }

    private function record(string $attemptId, array $o, array $attempt): array
    {
        if ($o['status'] === 'unknown') {
            return ['status' => 'unknown', 'attempt' => $attempt,
                'message' => 'HitPay had a problem answering. Check the HitPay dashboard before trying again.'];
        }
        $saved = $this->repo->finishGatewayRefund($attemptId, $o['status'], $o['refund_id'] ?? null, $o['error'] ?? null);
        $peso = '₱'.number_format((float) $attempt['amount'], 2);

        return ['status' => $o['status'], 'attempt' => $saved, 'message' => match ($o['status']) {
            'succeeded' => "{$peso} was sent back through HitPay (refund {$o['refund_id']}). The refund is completed.",
            'pending' => "HitPay accepted the refund of {$peso} and is still processing it (refund {$o['refund_id']}). Use \"Check HitPay\" later.",
            default => 'HitPay refused the refund: '.($o['error'] ?? 'no reason given').'. The refund is still approved: fix the problem and try again, or refund from the HitPay dashboard.',
        }];
    }

    /** Maps a HitPay HTTP answer: succeeded | pending | failed | unknown (+ refund_id, error). */
    public static function outcome(int $http, mixed $body): array
    {
        $body = is_array($body) ? $body : [];
        if ($http >= 200 && $http < 300 && is_string($body['id'] ?? null)) {
            $s = strtolower((string) ($body['status'] ?? ''));

            return match (true) {
                in_array($s, ['succeeded', 'success', 'completed', 'refunded'], true) => ['status' => 'succeeded', 'refund_id' => $body['id']],
                in_array($s, ['failed', 'cancelled', 'canceled', 'rejected'], true) => ['status' => 'failed', 'refund_id' => $body['id'], 'error' => "HitPay refund {$s}"],
                default => ['status' => 'pending', 'refund_id' => $body['id']],
            };
        }
        if ($http >= 400 && $http < 500) {
            $msg = is_string($body['message'] ?? null) ? $body['message'] : "HitPay refused the refund (HTTP {$http})";

            return ['status' => 'failed', 'error' => mb_substr($msg, 0, 250)];
        }

        return ['status' => 'unknown'];
    }
}
