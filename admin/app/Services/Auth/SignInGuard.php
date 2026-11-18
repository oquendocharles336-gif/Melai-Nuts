<?php

namespace App\Services\Auth;

use App\Services\Shop\SupabaseRest;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * The server-side sign-in counter (Supabase Edge Function `auth-guard`), shared with the app.
 * Called by THIS server before every Firebase password sign-in, so a website visitor cannot
 * skip it: after 15 attempts in 30 minutes for the e-mail or the visitor's IP, the sign-in
 * needs a Turnstile token, verified by the function (single use). Never a lockout.
 *
 * The visitor's IP is passed with the shared AUTH_GUARD_SERVER_KEY; without that key every
 * visitor would share this server's IP.
 */
class SignInGuard
{
    public const PROCEED = 'proceed';

    public const CAPTCHA_REQUIRED = 'captcha_required';

    public const CAPTCHA_INVALID = 'captcha_invalid';

    /** The last precheck let the attempt through only because of a solved check (15+ attempts). */
    public bool $captchaWasNeeded = false;

    public function __construct(private SupabaseRest $rest) {}

    public function enabled(): bool
    {
        return $this->rest->configured() && strlen((string) config('melai.captcha.guard_server_key')) >= 32;
    }

    /**
     * One of PROCEED | CAPTCHA_REQUIRED | CAPTCHA_INVALID. If the guard cannot be reached the
     * sign-in proceeds (Firebase still checks the password and throttles), and it is logged.
     */
    public function precheck(string $email, ?string $ip, ?string $captchaToken): string
    {
        if (! $this->enabled()) {
            return self::PROCEED;
        }
        try {
            $r = $this->client()->withHeaders(array_filter(['X-Client-IP' => $ip]))
                ->post($this->rest->url().'/functions/v1/auth-guard/sign-in/precheck', [
                    'email' => $email,
                    'captcha_token' => (string) $captchaToken,
                ]);
        } catch (ConnectionException $e) {
            Log::warning('[auth] sign-in guard unreachable: '.$e->getMessage());

            return self::PROCEED;
        }
        if ($r->status() === 428) {
            return self::CAPTCHA_REQUIRED;
        }
        if (in_array($r->json('code'), ['captcha_invalid', 'captcha_unavailable'], true)) {
            return self::CAPTCHA_INVALID;
        }
        if (! $r->successful()) {
            Log::warning('[auth] sign-in guard answered '.$r->status());
        }
        $this->captchaWasNeeded = $r->json('captcha_required') === true;

        return self::PROCEED;
    }

    /** After a successful Firebase sign-in: clears that e-mail's counter. Never throws. */
    public function succeeded(string $idToken): void
    {
        if (! $this->enabled()) {
            return;
        }
        try {
            $this->client()->withToken($idToken)->post($this->rest->url().'/functions/v1/auth-guard/sign-in/success', ['source' => 'web']);
        } catch (\Throwable $e) {
            Log::warning('[auth] sign-in guard reset failed: '.$e->getMessage());
        }
    }

    private function client(): \Illuminate\Http\Client\PendingRequest
    {
        return Http::acceptJson()->asJson()->timeout(10)->withHeaders([
            'apikey' => (string) config('melai.shop.anon_key'),
            'X-Guard-Server-Key' => (string) config('melai.captcha.guard_server_key'),
        ]);
    }
}
