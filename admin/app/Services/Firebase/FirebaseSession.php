<?php

namespace App\Services\Firebase;

use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Models\User;
use App\Services\Auth\LinkState;
use Illuminate\Contracts\Encryption\DecryptException;
use Illuminate\Support\Facades\Crypt;

/**
 * The signed-in user's Firebase identity for this browser session.
 *
 * After a Firebase sign-in the session keeps the ID token, its expiry and the (encrypted)
 * refresh token. Every time the website is about to act as the user's app account in Supabase,
 * claimsFor() re-verifies the ID token (signature, project, expiry) and that it belongs to this
 * login; an expired token is refreshed with Firebase, which also fails once the account is
 * disabled, deleted or its sessions are revoked, so such users are cut off within minutes.
 */
class FirebaseSession
{
    private const KEY = 'firebase_auth';
    private const REFRESH_BEFORE = 120; // seconds before expiry

    private ?array $verified = null;

    public function __construct(
        private FirebaseConfig $config,
        private FirebaseAuthClient $client,
        private FirebaseTokenVerifier $verifier,
    ) {}

    /** Store a freshly verified sign-in. $tokens from FirebaseAuthClient, $claims from FirebaseTokenVerifier. */
    public function store(array $tokens, array $claims): void
    {
        session()->put(self::KEY, [
            'uid' => $claims['sub'],
            'id_token' => $tokens['id_token'],
            'refresh_token' => Crypt::encryptString($tokens['refresh_token']),
            'expires_at' => min($claims['exp'], time() + max(60, (int) ($tokens['expires_in'] ?? 3600))),
        ]);
        $this->verified = $claims;
    }

    public function forget(): void
    {
        session()->forget(self::KEY);
        $this->verified = null;
    }

    public function has(): bool
    {
        return is_array(session(self::KEY));
    }

    /**
     * Verified claims of the current session's Firebase user, who must be $user's Firebase identity.
     *
     * @throws FirebaseSessionRequiredException (state config_missing / not_authenticated)
     * @throws BackendUnavailableException when Firebase cannot be reached to refresh the token
     */
    public function claimsFor(User $user, bool $forceRefresh = false): array
    {
        if (! $this->config->ready()) {
            throw new FirebaseSessionRequiredException(LinkState::CONFIG_MISSING, $this->config->missingMessage());
        }
        $s = session(self::KEY);
        if (! is_array($s) || blank($user->firebase_uid) || ($s['uid'] ?? null) !== $user->firebase_uid) {
            throw new FirebaseSessionRequiredException(LinkState::NOT_AUTHENTICATED,
                'Please sign in with your Melai Nuts app email and password. Business pages act as your app account, so they need a current app sign-in (the website links your account automatically).');
        }
        if (! $forceRefresh && $this->verified !== null && $this->verified['sub'] === $s['uid'] && $this->verified['exp'] > time() + self::REFRESH_BEFORE) {
            return $this->verified;
        }

        try {
            if ($forceRefresh || (int) $s['expires_at'] <= time() + self::REFRESH_BEFORE) {
                $s = $this->refresh($s);
            }
            $claims = $this->verifier->verify($s['id_token']);
        } catch (FirebaseAuthException $e) {
            if ($e->isTemporary() || $e->reason === FirebaseAuthException::NETWORK) {
                throw new BackendUnavailableException($e->getMessage());
            }
            $this->forget();
            throw new FirebaseSessionRequiredException(
                $e->reason === FirebaseAuthException::CONFIG ? LinkState::CONFIG_MISSING : LinkState::NOT_AUTHENTICATED,
                $e->getMessage(), $e);
        }

        if ($claims['sub'] !== $user->firebase_uid) {
            $this->forget();
            throw new FirebaseSessionRequiredException(LinkState::NOT_AUTHENTICATED, 'The app sign-in in this session belongs to another account. Please sign in again.');
        }

        return $this->verified = $claims;
    }

    /** A currently valid ID token of $user (for Firestore requests made as the user). */
    public function idTokenFor(User $user): string
    {
        $this->claimsFor($user);

        return session(self::KEY)['id_token'];
    }

    private function refresh(array $s): array
    {
        try {
            $refreshToken = Crypt::decryptString((string) $s['refresh_token']);
        } catch (DecryptException) {
            throw new FirebaseAuthException(FirebaseAuthException::SESSION_ENDED, 'Your app sign-in has ended. Please sign in again.');
        }
        $t = $this->client->refresh($refreshToken);
        if ($t['uid'] !== $s['uid'] || $t['id_token'] === '') {
            throw new FirebaseAuthException(FirebaseAuthException::SESSION_ENDED, 'Your app sign-in has ended. Please sign in again.');
        }
        $s = [
            'uid' => $s['uid'],
            'id_token' => $t['id_token'],
            'refresh_token' => Crypt::encryptString($t['refresh_token'] ?: $refreshToken),
            'expires_at' => time() + max(60, $t['expires_in']),
        ];
        session()->put(self::KEY, $s);
        $this->verified = null;

        return $s;
    }
}
