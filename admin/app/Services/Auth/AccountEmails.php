<?php

namespace App\Services\Auth;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * The account e-mails, sent by the Supabase Edge Function `account-email` with our own template
 * and our own single-use links (no Firebase e-mails any more):
 *   password reset (request / check / confirm), e-mail change (request / confirm / cancel) and the
 *   "a second sign-in step was added" security notice.
 *
 * Firebase stays the identity: the function changes the password / e-mail with the Firebase Admin
 * credentials. This class only forwards; it passes the visitor's IP with the shared
 * AUTH_GUARD_SERVER_KEY (same as the sign-in guard) so the per-IP limits count the visitor.
 */
class AccountEmails
{
    public function configured(): bool
    {
        return filled($this->base()) && filled(config('melai.shop.anon_key'));
    }

    /** Never says whether the address has an account. @throws AccountEmailException */
    public function requestPasswordReset(string $email, ?string $ip = null): void
    {
        $this->post('password-reset/request', ['email' => mb_strtolower(trim($email))], ip: $ip);
    }

    /** @return array{email: string, email_masked: string} @throws AccountEmailException */
    public function checkPasswordReset(string $token): array
    {
        $r = $this->post('password-reset/check', ['token' => $token]);

        return ['email' => (string) $r->json('email', ''), 'email_masked' => (string) $r->json('email_masked', '')];
    }

    /** Sets the new password (single use) and ends the account's other sign-ins. @return string the e-mail */
    public function confirmPasswordReset(string $token, string $password): string
    {
        return (string) $this->post('password-reset/confirm', ['token' => $token, 'password' => $password])->json('email', '');
    }

    /** $idToken must be fresh (the password was just checked). @throws AccountEmailException */
    public function requestEmailChange(string $idToken, string $newEmail, ?string $ip = null): string
    {
        return (string) $this->post('email-change/request', ['new_email' => mb_strtolower(trim($newEmail))], $idToken, $ip)->json('message', '');
    }

    /** @return string the new e-mail address @throws AccountEmailException */
    public function confirmEmailChange(string $token): string
    {
        return (string) $this->post('email-change/confirm', ['token' => $token])->json('email', '');
    }

    /** @throws AccountEmailException */
    public function cancelEmailChange(string $token): void
    {
        $this->post('email-change/cancel', ['token' => $token]);
    }

    /** Best effort: a security notice must never block turning two-step sign-in on. */
    public function notifyMfaEnrolled(string $email, ?string $userAgent, ?string $name = null): void
    {
        try {
            // $name: the greeting ("Hi Maria,"); the function keeps only the cleaned first name.
            $this->post('security-notice/mfa-enrolled', ['email' => $email, 'user_agent' => (string) $userAgent, 'name' => (string) $name]);
        } catch (AccountEmailException $e) {
            Log::warning('[account-email] MFA notice not sent', ['code' => $e->reason]);
        }
    }

    // ------------------------------------------------------------------------------------------

    private function base(): string
    {
        return rtrim((string) config('melai.shop.supabase_url'), '/');
    }

    private function post(string $path, array $body, ?string $idToken = null, ?string $ip = null): Response
    {
        if (! $this->configured()) {
            throw new AccountEmailException('Account emails are not set up yet. Please try again later.', 'not_configured');
        }
        $headers = ['apikey' => (string) config('melai.shop.anon_key'), 'Authorization' => 'Bearer '.($idToken ?: (string) config('melai.shop.anon_key'))];
        $key = (string) config('melai.captcha.guard_server_key');
        if (strlen($key) >= 32) {
            $headers['X-Guard-Server-Key'] = $key;
            $headers['X-Client-Ip'] = (string) ($ip ?? request()?->ip());
        }
        try {
            $r = Http::acceptJson()->asJson()->timeout(20)->withHeaders($headers)
                ->post($this->base().'/functions/v1/account-email/'.$path, $body);
        } catch (ConnectionException) {
            throw new AccountEmailException('We couldn\'t reach the email service. Please try again in a moment.', 'offline');
        }
        if ($r->successful()) {
            return $r;
        }
        $code = (string) ($r->json('code') ?? '');
        Log::info('[account-email] refused', ['path' => $path, 'status' => $r->status(), 'code' => $code]);
        throw new AccountEmailException(self::message($code, (string) ($r->json('error') ?? ''), (int) ($r->json('retry_after') ?? 0)), $code ?: 'failed', (int) ($r->json('retry_after') ?? 0));
    }

    /** Visitor-facing text for the function's answer codes. */
    public static function message(string $code, string $fallback = '', int $retryAfter = 0): string
    {
        return match ($code) {
            'cooldown' => 'Please wait '.max($retryAfter, 1).' seconds before asking again.',
            'hourly_limit' => 'Too many requests. Please try again later.',
            'link_used' => 'This link was already used. Ask for a new one.',
            'link_expired' => 'This link has expired. Ask for a new one.',
            'link_invalid' => 'This link is not valid. Open the link from the most recent Melai Nuts email.',
            'reauth_required', 'unauthorized' => 'Please enter your current password again.',
            'same_email' => 'That is already your email address.',
            'invalid_email' => 'Please enter a valid email address.',
            'email_taken' => 'That email address can\'t be used. Please choose another one.',
            'weak_password' => $fallback !== '' ? $fallback : 'Please choose a stronger password.',
            'captcha_required', 'captcha_invalid' => 'Please complete the security check and try again.',
            'not_configured' => 'Account emails are not set up yet. Please try again later.',
            default => 'Something went wrong. Please try again in a moment.',
        };
    }
}
