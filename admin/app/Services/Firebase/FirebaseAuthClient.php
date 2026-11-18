<?php

namespace App\Services\Firebase;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * Firebase Authentication REST API (Identity Toolkit + Secure Token), called server-to-server
 * over TLS with the app's public Web API key. This is the same API the Firebase Web SDK uses,
 * so accounts created here are ordinary Firebase Auth users of the Melai Nuts project (the
 * project's blocking functions in ../functions run for them as for app sign-ups).
 *
 * No service-account credentials are used or needed. Passwords are sent only to Google and
 * are never stored or logged; tokens are returned to the caller and never logged.
 */
class FirebaseAuthClient
{
    private const IDENTITY = 'https://identitytoolkit.googleapis.com/v1/';
    private const SECURE_TOKEN = 'https://securetoken.googleapis.com/v1/token';
    private const PROJECT_CONFIG = 'https://www.googleapis.com/identitytoolkit/v3/relyingparty/getProjectConfig';

    public function __construct(private FirebaseConfig $config) {}

    /** @return array{uid: string, email: string, id_token: string, refresh_token: string, expires_in: int} */
    public function signIn(string $email, string $password): array
    {
        $r = $this->identity('accounts:signInWithPassword', ['email' => $email, 'password' => $password, 'returnSecureToken' => true]);

        return $this->tokens($r);
    }

    /** Creates a new Firebase Auth user. @return array{uid, email, id_token, refresh_token, expires_in} */
    public function signUp(string $email, string $password, ?string $displayName = null): array
    {
        $body = ['email' => $email, 'password' => $password, 'returnSecureToken' => true];
        if (filled($displayName)) {
            $body['displayName'] = $displayName;
        }

        return $this->tokens($this->identity('accounts:signUp', $body));
    }

    /** Exchanges a refresh token for a fresh ID token. @return array{uid, id_token, refresh_token, expires_in} */
    public function refresh(string $refreshToken): array
    {
        $r = $this->send(fn () => Http::asForm()->timeout(15)->acceptJson()
            ->post(self::SECURE_TOKEN.'?key='.urlencode($this->key()), ['grant_type' => 'refresh_token', 'refresh_token' => $refreshToken]));

        if ($r->failed()) {
            throw $this->error($r, 'token');
        }

        return [
            'uid' => (string) $r->json('user_id', ''),
            'id_token' => (string) $r->json('id_token', ''),
            'refresh_token' => (string) $r->json('refresh_token', ''),
            'expires_in' => (int) $r->json('expires_in', 3600),
        ];
    }

    // No sendEmailVerification here on purpose: Firebase's verification-link e-mail is not used.
    // The 6-digit code comes from the Supabase Edge Function email-verification
    // (App\Services\Auth\EmailCodes).

    // No password-reset / e-mail-change e-mails here either: our own links and template come from
    // the Supabase Edge Function account-email (App\Services\Auth\AccountEmails).

    // --- Verifying a mobile number for the signed-in account (SMS one-time code) ---------------
    // The same Identity Toolkit calls the Firebase Web SDK makes for linkWithPhoneNumber. Firebase
    // sends and checks the code; once linked, the number is in the account's ID token as
    // `phone_number`, which is all the database accepts (claim_verified_phone).

    /** The reCAPTCHA site key Firebase expects for phone verification on the web. */
    public function recaptchaSiteKey(): string
    {
        $r = $this->send(fn () => Http::timeout(15)->acceptJson()->get(self::IDENTITY.'recaptchaParams', ['key' => $this->key()]));
        if ($r->failed()) {
            throw $this->error($r, 'recaptchaParams');
        }
        $key = (string) $r->json('recaptchaSiteKey', '');
        if ($key === '') {
            throw new FirebaseAuthException(FirebaseAuthException::CONFIG, 'Phone verification is not enabled in the Firebase project (Authentication > Sign-in method > Phone).');
        }

        return $key;
    }

    /** SMSes a code to $phoneE164. Returns the sessionInfo to pass to linkPhoneNumber(). */
    public function sendPhoneCode(string $phoneE164, string $recaptchaToken): string
    {
        $r = $this->identity('accounts:sendVerificationCode', ['phoneNumber' => $phoneE164, 'recaptchaToken' => $recaptchaToken]);
        $session = (string) $r->json('sessionInfo', '');
        if ($session === '') {
            throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, 'The SMS could not be sent. Please try again.');
        }

        return $session;
    }

    /**
     * Checks the SMS code and links the number to the account of $idToken (or replaces its number).
     *
     * @return array{uid: string, id_token: string, refresh_token: string, expires_in: int}
     */
    public function linkPhoneNumber(string $idToken, string $sessionInfo, string $code): array
    {
        $r = $this->identity('accounts:signInWithPhoneNumber', ['idToken' => $idToken, 'sessionInfo' => $sessionInfo, 'code' => $code]);
        $out = [
            'uid' => (string) $r->json('localId', ''),
            'id_token' => (string) $r->json('idToken', ''),
            'refresh_token' => (string) $r->json('refreshToken', ''),
            'expires_in' => (int) $r->json('expiresIn', 3600),
        ];
        if ($out['uid'] === '' || $out['id_token'] === '') {
            throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, 'The number could not be verified. Please try again.');
        }

        return $out;
    }

    /** Deletes the account the ID token belongs to (rollback of a half-finished registration). */
    public function deleteAccount(string $idToken): void
    {
        $this->identity('accounts:delete', ['idToken' => $idToken]);
    }

    /** The Firebase project the configured API key belongs to (used to catch a key from another project). */
    public function projectIdOfApiKey(): string
    {
        $r = $this->send(fn () => Http::timeout(15)->acceptJson()->get(self::PROJECT_CONFIG, ['key' => $this->key()]));
        if ($r->failed()) {
            throw $this->error($r, 'getProjectConfig');
        }

        return (string) $r->json('projectId', '');
    }

    // ---------------------------------------------------------------------------------------

    private function key(): string
    {
        $key = $this->config->apiKey();
        if ($key === null) {
            throw new FirebaseAuthException(FirebaseAuthException::CONFIG, $this->config->missingMessage() ?: 'FIREBASE_WEB_API_KEY is empty.');
        }

        return $key;
    }

    private function identity(string $method, array $body): Response
    {
        $r = $this->send(fn () => Http::timeout(15)->acceptJson()->post(self::IDENTITY.$method.'?key='.urlencode($this->key()), $body));
        if ($r->failed()) {
            throw $this->error($r, $method);
        }

        return $r;
    }

    private function send(\Closure $request): Response
    {
        try {
            return $request();
        } catch (ConnectionException $e) {
            Log::warning('[firebase] could not reach Firebase Authentication: '.$e->getMessage());
            throw new FirebaseAuthException(FirebaseAuthException::NETWORK, 'Could not reach the Melai Nuts app sign-in service (Firebase). Check the internet connection and try again in a moment.');
        }
    }

    private function tokens(Response $r): array
    {
        $out = [
            'uid' => (string) $r->json('localId', ''),
            'email' => mb_strtolower(trim((string) $r->json('email', ''))),
            'id_token' => (string) $r->json('idToken', ''),
            'refresh_token' => (string) $r->json('refreshToken', ''),
            'expires_in' => (int) $r->json('expiresIn', 3600),
        ];
        if ($out['uid'] === '' || $out['id_token'] === '' || $out['refresh_token'] === '') {
            throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, 'The app sign-in service returned an unexpected answer. Please try again.');
        }

        return $out;
    }

    /** Maps Firebase's error codes to a reason + a message that says what to do. */
    private function error(Response $r, string $method): FirebaseAuthException
    {
        $raw = (string) ($r->json('error.message') ?? (is_string($r->json('error')) ? $r->json('error') : ''));
        $code = strtoupper(trim((string) strtok($raw, ' :')));
        $reasons = collect((array) $r->json('error.details', []))->pluck('reason')->filter()->map(fn ($x) => strtoupper((string) $x));
        $status = strtoupper((string) $r->json('error.status', ''));
        Log::info('[firebase] request refused', ['method' => $method, 'http' => $r->status(), 'code' => $code, 'reasons' => $reasons->all()]);

        $configHint = 'Check FIREBASE_WEB_API_KEY in admin/.env (Firebase console > Project settings > General > Web API key) and run php artisan melai:firebase-check.';

        return match (true) {
            in_array($code, ['INVALID_LOGIN_CREDENTIALS', 'INVALID_PASSWORD'], true) => new FirebaseAuthException(FirebaseAuthException::INVALID_CREDENTIALS, 'The app email or password is incorrect, or this email has no Melai Nuts app account.', $code),
            $code === 'EMAIL_NOT_FOUND' => new FirebaseAuthException(FirebaseAuthException::ACCOUNT_NOT_FOUND, 'There is no Melai Nuts app account with this email.', $code),
            $code === 'EMAIL_EXISTS' => new FirebaseAuthException(FirebaseAuthException::EMAIL_EXISTS, 'A Melai Nuts app account with this email already exists.', $code),
            $code === 'WEAK_PASSWORD' => new FirebaseAuthException(FirebaseAuthException::WEAK_PASSWORD, 'Firebase rejected the password as too weak. Use at least 8 characters with upper- and lowercase letters, a number and a symbol.', $code),
            $code === 'INVALID_EMAIL' => new FirebaseAuthException(FirebaseAuthException::INVALID_EMAIL, 'Firebase rejected this email address.', $code),
            $code === 'USER_DISABLED' => new FirebaseAuthException(FirebaseAuthException::USER_DISABLED, 'This Melai Nuts app account is disabled. Ask the owner to reactivate it in the app\'s User Management.', $code),
            str_starts_with($code, 'TOO_MANY_ATTEMPTS') => new FirebaseAuthException(FirebaseAuthException::TOO_MANY_ATTEMPTS, 'Too many attempts on this app account. Wait a few minutes and try again.', $code),
            in_array($code, ['TOKEN_EXPIRED', 'INVALID_REFRESH_TOKEN', 'USER_NOT_FOUND', 'INVALID_ID_TOKEN', 'CREDENTIAL_TOO_OLD_LOGIN_AGAIN'], true) => new FirebaseAuthException(FirebaseAuthException::SESSION_ENDED, 'Your app sign-in has ended (password changed, account disabled or deleted, or sessions revoked). Please sign in again.', $code),
            in_array($code, ['EXPIRED_OOB_CODE', 'INVALID_OOB_CODE'], true) => new FirebaseAuthException(FirebaseAuthException::LINK_INVALID, $code === 'EXPIRED_OOB_CODE'
                ? 'This link has expired. Request a new one.'
                : 'This link was already used or is not valid anymore. Request a new one.', $code),
            in_array($code, ['INVALID_CODE', 'INVALID_VERIFICATION_CODE'], true) => new FirebaseAuthException(FirebaseAuthException::PHONE_CODE, 'That code is not correct. Please check the SMS and try again.', $code),
            in_array($code, ['SESSION_EXPIRED', 'INVALID_SESSION_INFO', 'MISSING_SESSION_INFO', 'CODE_EXPIRED'], true) => new FirebaseAuthException(FirebaseAuthException::PHONE_CODE, 'That code has expired. Please request a new code.', $code),
            in_array($code, ['INVALID_PHONE_NUMBER', 'MISSING_PHONE_NUMBER'], true) => new FirebaseAuthException(FirebaseAuthException::PHONE_CODE, 'That mobile number is not valid. Please check it and try again.', $code),
            in_array($code, ['CAPTCHA_CHECK_FAILED', 'MISSING_RECAPTCHA_TOKEN', 'INVALID_RECAPTCHA_TOKEN'], true) => new FirebaseAuthException(FirebaseAuthException::PHONE_CODE, 'The security check failed. Please complete it again.', $code),
            $code === 'QUOTA_EXCEEDED' => new FirebaseAuthException(FirebaseAuthException::TOO_MANY_ATTEMPTS, 'We have sent too many codes right now. Please try again later.', $code),
            in_array($code, ['PHONE_NUMBER_EXISTS', 'CREDENTIAL_ALREADY_IN_USE', 'FEDERATED_USER_ID_ALREADY_LINKED'], true)
                => new FirebaseAuthException(FirebaseAuthException::PHONE_TAKEN, 'This mobile number is already used by another Melai Nuts account. Sign in to that account, or use a different number.', $code),
            $code === 'OPERATION_NOT_ALLOWED' => new FirebaseAuthException(FirebaseAuthException::CONFIG, 'Email/password sign-in is disabled in the Firebase project. Enable it in Firebase console > Authentication > Sign-in method.', $code),
            $code === 'PROJECT_NOT_FOUND' || $reasons->contains('API_KEY_INVALID') || str_contains($raw, 'API key not valid')
                => new FirebaseAuthException(FirebaseAuthException::CONFIG, 'Firebase does not accept the configured Web API key. '.$configHint, $code ?: 'API_KEY_INVALID'),
            $reasons->contains('API_KEY_HTTP_REFERRER_BLOCKED') || $reasons->contains('API_KEY_IP_ADDRESS_BLOCKED') || $reasons->contains('API_KEY_SERVICE_BLOCKED')
                => new FirebaseAuthException(FirebaseAuthException::CONFIG, 'The Web API key is restricted (Google Cloud console > APIs & Services > Credentials) so this server may not use it. Allow this server\'s IP and the "Identity Toolkit API" and "Token Service API", or create a separate server key for the website. '.$configHint, $reasons->first()),
            $reasons->contains('SERVICE_DISABLED') || $status === 'PERMISSION_DENIED'
                => new FirebaseAuthException(FirebaseAuthException::CONFIG, 'The Identity Toolkit API is not enabled for this key\'s Google Cloud project, or the key belongs to another project. '.$configHint, $reasons->first() ?: $status),
            $r->serverError() => new FirebaseAuthException(FirebaseAuthException::NETWORK, 'The Melai Nuts app sign-in service (Firebase) is temporarily unavailable. Please try again in a moment.', $code),
            default => new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, 'The app sign-in service refused the request ('.($code ?: 'HTTP '.$r->status()).'). Please try again.', $code),
        };
    }
}
