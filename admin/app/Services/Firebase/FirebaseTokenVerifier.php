<?php

namespace App\Services\Firebase;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

/**
 * Verifies a Firebase Authentication ID token the way the Admin SDK does
 * (https://firebase.google.com/docs/auth/admin/verify-id-tokens#verify_id_tokens_using_a_third-party_jwt_library):
 *
 *  - RS256 signature by one of Google's securetoken public keys (fetched and cached per Cache-Control),
 *  - aud = FIREBASE_PROJECT_ID, iss = https://securetoken.google.com/<project>,
 *  - exp in the future, iat / auth_time not in the future, sub = non-empty UID (<= 128 chars).
 *
 * Only a token that passes all checks is ever turned into a UID. Uses PHP's OpenSSL; no extra package.
 */
class FirebaseTokenVerifier
{
    public const CERTS_URL = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
    public const CERTS_CACHE_KEY = 'firebase.securetoken.certs';
    private const LEEWAY = 60; // seconds of clock skew tolerated

    public function __construct(private FirebaseConfig $config) {}

    /**
     * @return array{sub: string, email: string, email_verified: bool, exp: int, auth_time: int, claims: array}
     * @throws FirebaseAuthException INVALID_TOKEN / CONFIG / NETWORK
     */
    public function verify(string $idToken): array
    {
        $project = $this->config->projectId();
        if ($project === null) {
            throw new FirebaseAuthException(FirebaseAuthException::CONFIG, $this->config->missingMessage());
        }

        $parts = explode('.', $idToken);
        if (count($parts) !== 3) {
            throw $this->invalid('malformed');
        }
        [$h64, $p64, $s64] = $parts;
        $header = json_decode($this->b64($h64), true);
        $payload = json_decode($this->b64($p64), true);
        $signature = $this->b64($s64);
        if (! is_array($header) || ! is_array($payload) || $signature === '') {
            throw $this->invalid('malformed');
        }
        if (($header['alg'] ?? null) !== 'RS256' || ! is_string($header['kid'] ?? null)) {
            throw $this->invalid('wrong algorithm');
        }

        // Project checks first: a token from another Firebase project means the API key is from that project.
        $aud = (string) ($payload['aud'] ?? '');
        if ($aud !== $project || ($payload['iss'] ?? null) !== 'https://securetoken.google.com/'.$project) {
            throw new FirebaseAuthException(FirebaseAuthException::CONFIG,
                "The app sign-in service issued a token for Firebase project \"{$aud}\", but FIREBASE_PROJECT_ID is \"{$project}\". "
                .'FIREBASE_WEB_API_KEY must be the Web API key of the same project as the Melai Nuts app (see ../.firebaserc). Run php artisan melai:firebase-check.');
        }

        $cert = $this->certificates()[$header['kid']] ?? $this->certificates(refresh: true)[$header['kid']] ?? null;
        if ($cert === null) {
            throw $this->invalid('unknown signing key');
        }
        $key = openssl_pkey_get_public($cert);
        if ($key === false || openssl_verify($h64.'.'.$p64, $signature, $key, OPENSSL_ALGO_SHA256) !== 1) {
            throw $this->invalid('bad signature');
        }

        $now = time();
        $sub = $payload['sub'] ?? null;
        if (! is_string($sub) || $sub === '' || strlen($sub) > 128) {
            throw $this->invalid('no subject');
        }
        if (! is_numeric($payload['exp'] ?? null) || (int) $payload['exp'] <= $now - self::LEEWAY) {
            throw new FirebaseAuthException(FirebaseAuthException::INVALID_TOKEN, 'Your app sign-in has expired. Please sign in again.', 'expired');
        }
        if (! is_numeric($payload['iat'] ?? null) || (int) $payload['iat'] > $now + self::LEEWAY) {
            throw $this->invalid('issued in the future');
        }
        if (isset($payload['auth_time']) && (int) $payload['auth_time'] > $now + self::LEEWAY) {
            throw $this->invalid('authenticated in the future');
        }

        return [
            'sub' => $sub,
            'email' => mb_strtolower(trim((string) ($payload['email'] ?? ''))),
            'email_verified' => ($payload['email_verified'] ?? false) === true,
            'exp' => (int) $payload['exp'],
            'auth_time' => (int) ($payload['auth_time'] ?? 0),
            'claims' => $payload,
        ];
    }

    /** kid => PEM certificate. */
    private function certificates(bool $refresh = false): array
    {
        if (! $refresh && is_array($cached = Cache::get(self::CERTS_CACHE_KEY))) {
            return $cached;
        }

        try {
            $r = Http::timeout(10)->acceptJson()->get(self::CERTS_URL);
        } catch (ConnectionException) {
            throw new FirebaseAuthException(FirebaseAuthException::NETWORK, 'Could not download Google\'s sign-in keys to check the app sign-in. Please try again in a moment.');
        }
        $certs = $r->successful() ? $r->json() : null;
        if (! is_array($certs) || $certs === []) {
            throw new FirebaseAuthException(FirebaseAuthException::NETWORK, 'Google\'s sign-in keys are temporarily unavailable. Please try again in a moment.');
        }
        $ttl = preg_match('/max-age=(\d+)/', (string) $r->header('Cache-Control'), $m) ? max(60, (int) $m[1]) : 3600;
        Cache::put(self::CERTS_CACHE_KEY, $certs, $ttl);

        return $certs;
    }

    private function b64(string $s): string
    {
        return (string) base64_decode(strtr($s, '-_', '+/').str_repeat('=', (4 - strlen($s) % 4) % 4), true);
    }

    private function invalid(string $why): FirebaseAuthException
    {
        return new FirebaseAuthException(FirebaseAuthException::INVALID_TOKEN, 'The app sign-in could not be verified. Please sign in again.', $why);
    }
}
