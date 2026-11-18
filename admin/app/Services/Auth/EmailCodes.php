<?php

namespace App\Services\Auth;

use App\Services\Shop\SupabaseRest;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * The 6-digit e-mail code (Supabase Edge Function `email-verification`), the same backend the
 * app uses. It replaces Firebase's verification link: nothing on the website asks Firebase to
 * send an e-mail any more.
 *
 * The function takes the account and the address ONLY from the Firebase ID token, checks the
 * Turnstile token server-side before anything else, stores the code hashed and, on the right
 * code, marks the e-mail verified in Firebase. This class only forwards.
 */
class EmailCodes
{
    public function __construct(private SupabaseRest $rest) {}

    /** @throws EmailCodeException */
    public function send(string $idToken, ?string $captchaToken): void
    {
        $this->post('send-code', ['captcha_token' => (string) $captchaToken], $idToken, false);
    }

    /** @throws EmailCodeException */
    public function verify(string $idToken, string $code, ?string $captchaToken): void
    {
        $this->post('verify-code', ['code' => $code, 'captcha_token' => (string) $captchaToken], $idToken, true);
    }

    private function post(string $path, array $body, string $idToken, bool $verifying): void
    {
        if (! $this->rest->configured()) {
            throw new EmailCodeException('Email verification is not set up yet. Please try again later.', 'not_configured');
        }
        try {
            $r = Http::acceptJson()->asJson()->timeout(20)->withHeaders([
                'apikey' => (string) config('melai.shop.anon_key'),
                'Authorization' => 'Bearer '.$idToken,
            ])->post($this->rest->url().'/functions/v1/email-verification/'.$path, $body);
        } catch (ConnectionException $e) {
            throw new EmailCodeException('We couldn\'t reach the verification service. Please try again in a moment.', 'offline');
        }
        if ($r->successful()) {
            return;
        }
        $code = (string) ($r->json('code') ?? '');
        Log::info('[shop] email code refused', ['path' => $path, 'status' => $r->status(), 'code' => $code]);
        throw new EmailCodeException(self::message($code, $r->status(), $verifying, (int) ($r->json('retry_after') ?? 0)), $code ?: 'refused', (int) ($r->json('retry_after') ?? 0));
    }

    /** Customer-facing text for the function's answer codes. */
    public static function message(string $code, int $status, bool $verifying, int $retryAfter = 0): string
    {
        return match ($code) {
            'captcha_required' => 'Please complete the security check.',
            'captcha_invalid' => 'The security check expired or failed. Please do it again.',
            'captcha_unavailable' => 'The security check is unavailable right now. Please try again in a moment.',
            'wrong_code' => 'That code is incorrect. Please check the email and try again.',
            'code_expired' => 'That code has expired. Send a new code and try again.',
            'code_used' => 'That code was already used. Send a new code and try again.',
            'too_many_attempts' => 'Too many wrong codes. Send a new code and try again.',
            'cooldown' => 'Please wait '.max($retryAfter, 1).' seconds before asking for a new code.',
            'hourly_limit' => 'Too many codes were requested. Please try again later.',
            'invalid_code' => 'Please enter the 6-digit code from the email.',
            'unauthorized' => 'Your sign-up session expired. Please sign in again.',
            default => $status === 429 ? 'Too many attempts. Please wait a moment and try again.'
                : ($verifying ? 'We couldn\'t verify the code. Please try again.' : 'We couldn\'t send the code. Please try again.'),
        };
    }
}
