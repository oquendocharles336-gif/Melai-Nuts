<?php

namespace App\Services\Auth;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

/**
 * Cloudflare Turnstile on the website.
 *
 *   TURNSTILE_SITE_KEY    public, drawn into the page (shop.partials.turnstile)
 *   TURNSTILE_SECRET_KEY  private, used here to verify a token with Cloudflare (siteverify)
 *                         BEFORE the website creates an account
 *
 * Both are read from config/melai.php. When config:cache was built while a key was not set
 * (for example during a deploy build), config keeps an empty value although the variable is set
 * now: the real environment variable is then used and a warning is logged, so the form does not
 * break until the next `php artisan config:cache`.
 *
 * A token is single use. The sign-up token is checked here with an idempotency key, and the same
 * key goes on to the Supabase Edge Function email-verification, which checks the same token again
 * with that key (Cloudflare accepts a repeat with the same key) and records it as used.
 */
class Turnstile
{
    public const SITEVERIFY_URL = 'https://challenges.cloudflare.com/turnstile/v0/siteverify';

    private static bool $warned = false;

    public static function siteKey(): string
    {
        return self::read('melai.captcha.turnstile_site_key', 'TURNSTILE_SITE_KEY');
    }

    public static function secretKey(): string
    {
        return self::read('melai.captcha.turnstile_secret_key', 'TURNSTILE_SECRET_KEY');
    }

    /** True when the widget can be drawn. Logs (once per request) why not. */
    public static function ready(): bool
    {
        if (self::siteKey() !== '') {
            return true;
        }
        self::warnOnce('[turnstile] TURNSTILE_SITE_KEY is empty: the security check cannot be shown and new accounts cannot be created. Set it on the server and run php artisan config:clear (or config:cache).');

        return false;
    }

    /**
     * Verifies the widget's token for $action. Returns the idempotency key to pass on to the Edge
     * Function with the same token.
     *
     * @throws TurnstileException with a customer-facing message
     */
    public function verify(?string $token, string $action, ?string $ip): string
    {
        $token = trim((string) $token);
        if ($token === '') {
            throw new TurnstileException('Please complete the security check.', 'missing');
        }
        if (strlen($token) > 2048) {
            throw new TurnstileException('The security check failed. Please try again.', 'invalid');
        }
        $secret = self::secretKey();
        if ($secret === '') {
            Log::error('[turnstile] TURNSTILE_SECRET_KEY is empty: sign-up tokens cannot be verified, so no account is created. Set it on the server (same value as the Supabase function secret) and run php artisan config:clear.');
            throw new TurnstileException('The security check is not available right now, so we can\'t create accounts at the moment. Please try again later.', 'not_configured');
        }

        $key = (string) Str::uuid();
        try {
            $r = Http::asForm()->acceptJson()->timeout(8)->post(self::SITEVERIFY_URL, array_filter([
                'secret' => $secret,
                'response' => $token,
                'remoteip' => $ip,
                'idempotency_key' => $key,
            ]));
        } catch (ConnectionException $e) {
            Log::warning('[turnstile] siteverify unreachable', ['error' => $e->getMessage()]);
            throw new TurnstileException('The security check is unavailable right now. Please try again in a moment.', 'unavailable');
        }
        if (! $r->successful()) {
            Log::warning('[turnstile] siteverify failed', ['status' => $r->status()]);
            throw new TurnstileException('The security check is unavailable right now. Please try again in a moment.', 'unavailable');
        }
        if ($r->json('success') !== true) {
            $codes = (array) $r->json('error-codes', []);
            Log::info('[turnstile] token refused', ['codes' => $codes]);
            if (array_intersect($codes, ['invalid-input-secret', 'missing-input-secret']) !== []) {
                Log::error('[turnstile] Cloudflare does not accept TURNSTILE_SECRET_KEY (it must be the secret of the same widget as TURNSTILE_SITE_KEY).');
                throw new TurnstileException('The security check is not available right now, so we can\'t create accounts at the moment. Please try again later.', 'not_configured');
            }

            throw new TurnstileException(in_array('timeout-or-duplicate', $codes, true)
                ? 'The security check expired. Please do it again.'
                : 'The security check failed. Please try again.', 'invalid');
        }
        $got = (string) $r->json('action', '');
        if ($got !== '' && $got !== $action) {
            throw new TurnstileException('The security check failed. Please try again.', 'wrong_action');
        }
        $hosts = array_filter(array_map(fn ($h) => strtolower(trim($h)), explode(',', (string) config('melai.captcha.turnstile_hostnames'))));
        if ($hosts !== [] && ! in_array(strtolower((string) $r->json('hostname', '')), $hosts, true)) {
            throw new TurnstileException('The security check failed. Please try again.', 'wrong_host');
        }

        return $key;
    }

    private static function read(string $configKey, string $envName): string
    {
        $value = trim((string) config($configKey));
        if ($value !== '') {
            return $value;
        }
        // A real environment variable (Railway, Docker) set after config:cache was built.
        $live = getenv($envName);
        $live = is_string($live) ? trim($live) : '';
        if ($live !== '' && app()->configurationIsCached()) {
            self::warnOnce("[turnstile] $envName is set but the cached config has it empty: run php artisan config:clear (or config:cache) after changing environment variables.");

            return $live;
        }

        return '';
    }

    private static function warnOnce(string $message): void
    {
        if (! self::$warned) {
            self::$warned = true;
            Log::warning($message);
        }
    }
}
