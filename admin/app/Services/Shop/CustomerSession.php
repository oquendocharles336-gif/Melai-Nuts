<?php

namespace App\Services\Shop;

use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseTokenVerifier;
use Illuminate\Contracts\Encryption\DecryptException;
use Illuminate\Support\Facades\Crypt;

/**
 * The signed-in shop customer for this browser session.
 *
 * Kept under its own session key, completely apart from the admin website's login
 * (the `web` guard and the staff Firebase session, `firebase_auth`). A shop sign-in never
 * creates or touches a website `users` row, so it can never pass the admin `auth` check.
 *
 * Every time the shop acts as the customer, idToken() hands out a verified, unexpired Firebase
 * ID token (refreshed with Firebase when needed, which also fails once the account is disabled or
 * deleted) that carries `role: authenticated`, the claim Supabase needs, like the app's
 * SupabaseToken does.
 */
class CustomerSession
{
    public const KEY = 'shop_customer';

    private const REFRESH_BEFORE = 120; // seconds before expiry

    private ?array $verified = null;

    public function __construct(
        private FirebaseAuthClient $client,
        private FirebaseTokenVerifier $verifier,
        private SupabaseRest $rest,
    ) {}

    /** Store a verified customer sign-in. */
    public function start(array $tokens, array $claims, string $name, string $phone = ''): void
    {
        session()->regenerate();
        session()->put(self::KEY, [
            'uid' => $claims['sub'],
            'email' => (string) ($claims['email'] ?? ''),
            'name' => $name !== '' ? $name : 'Customer',
            'phone' => $phone,
            'id_token' => $tokens['id_token'],
            'refresh_token' => Crypt::encryptString($tokens['refresh_token']),
            'expires_at' => min((int) $claims['exp'], time() + max(60, (int) ($tokens['expires_in'] ?? 3600))),
        ]);
        $this->verified = $claims;
    }

    public function forget(): void
    {
        session()->forget(self::KEY);
        $this->verified = null;
    }

    /** A customer is signed in in this browser session (no network call). */
    public function check(): bool
    {
        $s = session(self::KEY);

        return is_array($s) && filled($s['uid'] ?? null);
    }

    public function uid(): ?string
    {
        return $this->check() ? (string) session(self::KEY)['uid'] : null;
    }

    public function name(): string
    {
        return $this->check() ? (string) (session(self::KEY)['name'] ?? 'Customer') : '';
    }

    public function firstName(): string
    {
        return explode(' ', trim($this->name()))[0] ?: 'there';
    }

    public function email(): string
    {
        return $this->check() ? (string) (session(self::KEY)['email'] ?? '') : '';
    }

    public function phone(): string
    {
        return $this->check() ? (string) (session(self::KEY)['phone'] ?? '') : '';
    }

    public function rememberPhone(string $phone): void
    {
        if ($this->check()) {
            session()->put(self::KEY.'.phone', $phone);
        }
    }

    /**
     * A currently valid ID token of the signed-in customer, with `role: authenticated`.
     *
     * @throws ShopException reason "session" when there is no usable sign-in (the session is cleared)
     */
    public function idToken(): string
    {
        $s = session(self::KEY);
        if (! is_array($s)) {
            throw new ShopException('Please sign in to continue.', 'session');
        }

        try {
            if ((int) $s['expires_at'] <= time() + self::REFRESH_BEFORE) {
                $s = $this->refresh($s);
            }
            $claims = ($this->verified !== null && $this->verified['sub'] === $s['uid'] && $this->verified['exp'] > time() + self::REFRESH_BEFORE)
                ? $this->verified
                : $this->verifier->verify($s['id_token']);
            if ($claims['sub'] !== $s['uid']) {
                throw new FirebaseAuthException(FirebaseAuthException::SESSION_ENDED, 'Please sign in again.');
            }
            if (($claims['claims']['role'] ?? null) !== 'authenticated') {
                $s = $this->grantRoleClaim($s);
                $claims = $this->verifier->verify($s['id_token']);
            }
        } catch (FirebaseAuthException $e) {
            if ($e->isTemporary() || $e->reason === FirebaseAuthException::NETWORK) {
                throw new ShopException('We couldn\'t reach the sign-in service. Please try again in a moment.', 'offline', previous: $e);
            }
            $this->forget();
            throw new ShopException('Your sign-in has ended. Please sign in again.', 'session', previous: $e);
        }
        $this->verified = $claims;

        return $s['id_token'];
    }

    /**
     * Supabase maps the token's `role` claim to a Postgres role; Firebase tokens have none until the
     * `grant-role-claim` Edge Function sets it on this account (exactly what the app does on first
     * sign-in). Then a refreshed token carries it.
     */
    private function grantRoleClaim(array $s): array
    {
        try {
            $this->rest->invoke('grant-role-claim', [], $s['id_token']);
        } catch (ShopException $e) {
            if ($e->reason === 'offline' || $e->reason === 'server') {
                throw new FirebaseAuthException(FirebaseAuthException::NETWORK, $e->getMessage());
            }
            throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, 'Your account could not be set up for the shop. Please try again.');
        }

        return $this->refresh($s);
    }

    private function refresh(array $s): array
    {
        try {
            $refreshToken = Crypt::decryptString((string) $s['refresh_token']);
        } catch (DecryptException) {
            throw new FirebaseAuthException(FirebaseAuthException::SESSION_ENDED, 'Please sign in again.');
        }
        $t = $this->client->refresh($refreshToken);
        if ($t['uid'] !== $s['uid'] || $t['id_token'] === '') {
            throw new FirebaseAuthException(FirebaseAuthException::SESSION_ENDED, 'Please sign in again.');
        }
        $s = array_merge($s, [
            'id_token' => $t['id_token'],
            'refresh_token' => Crypt::encryptString($t['refresh_token'] ?: $refreshToken),
            'expires_at' => time() + max(60, $t['expires_in']),
        ]);
        session()->put(self::KEY, $s);
        $this->verified = null;

        return $s;
    }
}
