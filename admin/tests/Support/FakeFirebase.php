<?php

namespace Tests\Support;

use App\Models\User;
use App\Services\Firebase\FirebaseTokenVerifier;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\Http;

/**
 * In-process stand-in for Firebase Authentication + the Firestore users collection, for tests.
 *
 * It answers the same REST endpoints the website calls (Identity Toolkit, Secure Token,
 * getProjectConfig, Firestore commit/get/delete) and issues REAL RS256-signed ID tokens with a
 * test key pair whose certificate is served as Google's securetoken key, so the production
 * FirebaseTokenVerifier checks every token exactly as in real use. No network is used.
 */
class FakeFirebase
{
    public const PROJECT = 'test-firebase-project'; // test-only id; never contacted
    public const API_KEY = 'test-web-api-key';
    public const KID = 'test-kid';

    private static ?array $keys = null;

    /** email => ['uid', 'password', 'verified', 'disabled', 'revoked'] */
    public array $accounts = [];
    /** Firestore users/{uid} => fields */
    public array $profiles = [];
    public array $verificationEmails = [];
    public array $resetEmails = [];
    public bool $offline = false;
    public bool $firestoreDenied = false;
    public bool $enumerationProtection = true;
    public ?string $keyProject = null;

    public static function keys(): array
    {
        if (self::$keys === null) {
            // PHP on Windows usually has no openssl.cnf where OpenSSL looks for it, and then
            // openssl_csr_new()/openssl_csr_sign() fail ("CSR cannot be retrieved"). A tiny
            // config written for the test run makes key generation work on every platform.
            $options = ['digest_alg' => 'sha256', 'config' => self::opensslConfig()];
            $key = openssl_pkey_new($options + ['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
            $csr = openssl_csr_new(['commonName' => 'securetoken.test'], $key, $options);
            $cert = openssl_csr_sign($csr, null, $key, 1, $options);
            openssl_pkey_export($key, $private, null, $options);
            openssl_x509_export($cert, $certPem);
            self::$keys = ['private' => $private, 'cert' => $certPem];
        }

        return self::$keys;
    }

    /** Path of a minimal OpenSSL config (test use only; holds no keys). */
    private static function opensslConfig(): string
    {
        $path = rtrim(sys_get_temp_dir(), '/\\').DIRECTORY_SEPARATOR.'melai-test-openssl.cnf';
        if (! is_file($path)) {
            file_put_contents($path, "[ req ]\ndistinguished_name = req_dn\n[ req_dn ]\n");
        }

        return $path;
    }

    public function install(): self
    {
        config([
            'services.firebase.web_api_key' => self::API_KEY,
            'services.firebase.project_id' => self::PROJECT,
            'services.firebase.firebaserc_path' => '', // the repository's real .firebaserc is not a test fixture
        ]);
        Cache::put(FirebaseTokenVerifier::CERTS_CACHE_KEY, [self::KID => self::keys()['cert']], 3600);

        Http::fake([
            'identitytoolkit.googleapis.com/v1/accounts:signInWithPassword*' => fn (Request $r) => $this->signIn($r),
            'identitytoolkit.googleapis.com/v1/accounts:signUp*' => fn (Request $r) => $this->signUp($r),
            'identitytoolkit.googleapis.com/v1/accounts:sendOobCode*' => fn (Request $r) => $this->oob($r),
            'identitytoolkit.googleapis.com/v1/accounts:delete*' => fn (Request $r) => $this->delete($r),
            'securetoken.googleapis.com/*' => fn (Request $r) => $this->refresh($r),
            'www.googleapis.com/identitytoolkit/v3/relyingparty/getProjectConfig*' => fn () => $this->offline ? Http::failedConnection()
                : Http::response(['projectId' => $this->keyProject ?? self::PROJECT]),
            'www.googleapis.com/robot/*' => fn () => Http::response([self::KID => self::keys()['cert']], 200, ['Cache-Control' => 'public, max-age=3600']),
            'firestore.googleapis.com/*' => fn (Request $r) => $this->firestore($r),
        ]);

        return $this;
    }

    public function addAccount(string $email, string $uid, string $password, bool $verified = false): self
    {
        $this->accounts[mb_strtolower($email)] = ['uid' => $uid, 'password' => $password, 'verified' => $verified, 'disabled' => false, 'revoked' => false];

        return $this;
    }

    public function account(string $uid): ?array
    {
        return collect($this->accounts)->first(fn ($a) => $a['uid'] === $uid);
    }

    public function set(string $uid, string $field, mixed $value): void
    {
        foreach ($this->accounts as $email => $a) {
            if ($a['uid'] === $uid) {
                $this->accounts[$email][$field] = $value;
            }
        }
    }

    /** A signed ID token. $override changes / adds claims; $privateKey signs with another key (forgery). */
    public function token(string $uid, string $email, bool $verified = false, array $override = [], ?string $privateKey = null, string $kid = self::KID): string
    {
        $now = time();
        $claims = array_merge([
            'iss' => 'https://securetoken.google.com/'.self::PROJECT, 'aud' => self::PROJECT, 'auth_time' => $now - 5,
            'user_id' => $uid, 'sub' => $uid, 'iat' => $now - 5, 'exp' => $now + 3600,
            'email' => mb_strtolower($email), 'email_verified' => $verified, 'role' => 'authenticated',
            'firebase' => ['sign_in_provider' => 'password'],
        ], $override);
        $enc = fn ($v) => rtrim(strtr(base64_encode(is_string($v) ? $v : json_encode($v)), '+/', '-_'), '=');
        $input = $enc(['alg' => 'RS256', 'kid' => $kid, 'typ' => 'JWT']).'.'.$enc($claims);
        openssl_sign($input, $sig, $privateKey ?? self::keys()['private'], OPENSSL_ALGO_SHA256);

        return $input.'.'.$enc($sig);
    }

    /** Session data of a fresh Firebase sign-in of $user (what the login controller stores). */
    public function sessionFor(User $user, int $expiresIn = 3600, ?string $idToken = null): array
    {
        $acc = $this->account($user->firebase_uid);
        $verified = $acc['verified'] ?? $user->firebase_email_verified;

        return ['firebase_auth' => [
            'uid' => $user->firebase_uid,
            'id_token' => $idToken ?? $this->token($user->firebase_uid, $user->email, $verified, ['exp' => time() + $expiresIn]),
            'refresh_token' => Crypt::encryptString('rt|'.$user->firebase_uid),
            'expires_at' => time() + $expiresIn,
        ]];
    }

    // ---- endpoints ------------------------------------------------------------------------

    private function err(string $message, int $status = 400, array $extra = [])
    {
        return Http::response(['error' => array_merge(['code' => $status, 'message' => $message], $extra)], $status);
    }

    private function tokensFor(array $acc, string $email): array
    {
        return ['localId' => $acc['uid'], 'email' => mb_strtolower($email), 'idToken' => $this->token($acc['uid'], $email, $acc['verified']),
            'refreshToken' => 'rt|'.$acc['uid'], 'expiresIn' => '3600', 'registered' => true];
    }

    private function signIn(Request $r)
    {
        if ($this->offline) {
            return Http::failedConnection();
        }
        if ($r['email'] === null) {
            return $this->err('INVALID_EMAIL');
        }
        $acc = $this->accounts[mb_strtolower($r['email'])] ?? null;
        if (! $acc) {
            return $this->err($this->enumerationProtection ? 'INVALID_LOGIN_CREDENTIALS' : 'EMAIL_NOT_FOUND');
        }
        if ($acc['password'] !== $r['password']) {
            return $this->err($this->enumerationProtection ? 'INVALID_LOGIN_CREDENTIALS' : 'INVALID_PASSWORD');
        }
        if ($acc['disabled']) {
            return $this->err('USER_DISABLED');
        }

        return Http::response($this->tokensFor($acc, $r['email']));
    }

    private function signUp(Request $r)
    {
        if ($this->offline) {
            return Http::failedConnection();
        }
        $email = mb_strtolower((string) $r['email']);
        if (isset($this->accounts[$email])) {
            return $this->err('EMAIL_EXISTS');
        }
        if (strlen((string) $r['password']) < 6) {
            return $this->err('WEAK_PASSWORD : Password should be at least 6 characters');
        }
        $this->addAccount($email, 'fb-'.substr(md5($email.microtime()), 0, 20), (string) $r['password']);

        return Http::response($this->tokensFor($this->accounts[$email], $email));
    }

    private function oob(Request $r)
    {
        if ($r['requestType'] === 'VERIFY_EMAIL') {
            $this->verificationEmails[] = $this->uidFromToken((string) $r['idToken']);
        } else {
            $this->resetEmails[] = mb_strtolower((string) $r['email']);
            if (! isset($this->accounts[mb_strtolower((string) $r['email'])]) && ! $this->enumerationProtection) {
                return $this->err('EMAIL_NOT_FOUND');
            }
        }

        return Http::response(['kind' => 'identitytoolkit#GetOobConfirmationCodeResponse']);
    }

    private function delete(Request $r)
    {
        $uid = $this->uidFromToken((string) $r['idToken']);
        $this->accounts = array_filter($this->accounts, fn ($a) => $a['uid'] !== $uid);

        return Http::response([]);
    }

    private function refresh(Request $r)
    {
        if ($this->offline) {
            return Http::failedConnection();
        }
        $uid = explode('|', (string) $r['refresh_token'])[1] ?? '';
        $found = null;
        foreach ($this->accounts as $email => $a) {
            if ($a['uid'] === $uid) {
                $found = [$email, $a];
            }
        }
        if (! $found) {
            return $this->err('USER_NOT_FOUND');
        }
        [$email, $a] = $found;
        if ($a['disabled']) {
            return $this->err('USER_DISABLED');
        }
        if ($a['revoked']) {
            return $this->err('TOKEN_EXPIRED');
        }

        return Http::response(['id_token' => $this->token($uid, $email, $a['verified']), 'refresh_token' => 'rt|'.$uid, 'expires_in' => '3600', 'user_id' => $uid]);
    }

    private function firestore(Request $r)
    {
        if ($this->firestoreDenied) {
            return Http::response(['error' => ['code' => 403, 'status' => 'PERMISSION_DENIED', 'message' => 'Missing or insufficient permissions.']], 403);
        }
        // Like firestore.rules: the caller (bearer ID token) must be an active owner profile.
        $caller = $this->uidFromToken(substr((string) $r->header('Authorization')[0], 7));
        if (($this->profiles[$caller]['role'] ?? null) !== 'owner') {
            return Http::response(['error' => ['code' => 403, 'status' => 'PERMISSION_DENIED', 'message' => 'Missing or insufficient permissions.']], 403);
        }
        if (str_ends_with(parse_url($r->url(), PHP_URL_PATH), ':commit')) {
            $w = $r['writes'][0];
            $uid = basename($w['update']['name']);
            if (isset($this->profiles[$uid])) {
                return Http::response(['error' => ['code' => 409, 'status' => 'ALREADY_EXISTS', 'message' => 'Document already exists']], 409);
            }
            $this->profiles[$uid] = collect($w['update']['fields'])->map(fn ($v) => reset($v))->all() + ['createdAt' => 'REQUEST_TIME'];

            return Http::response(['writeResults' => [[]]]);
        }
        $uid = rawurldecode(basename(parse_url($r->url(), PHP_URL_PATH)));
        if ($r->method() === 'DELETE') {
            unset($this->profiles[$uid]);

            return Http::response([]);
        }
        if (! isset($this->profiles[$uid])) {
            return Http::response(['error' => ['code' => 404, 'status' => 'NOT_FOUND']], 404);
        }

        return Http::response(['fields' => collect($this->profiles[$uid])->map(fn ($v) => is_bool($v) ? ['booleanValue' => $v] : ['stringValue' => (string) $v])->all()]);
    }

    private function uidFromToken(string $jwt): string
    {
        $p = json_decode((string) base64_decode(strtr(explode('.', $jwt)[1] ?? '', '-_', '+/')), true);

        return (string) ($p['sub'] ?? '');
    }
}
