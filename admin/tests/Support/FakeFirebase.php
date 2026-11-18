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
    /** account-email function (our own e-mails): link token => [kind, email, new_email, used] */
    public array $actionLinks = [];
    /** [uid, new_email] of every e-mail change asked for */
    public array $emailChangeRequests = [];
    /** Addresses that got the "second sign-in step added" notice */
    public array $mfaNotices = [];
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

    /** A fresh, unrelated RSA private key (PEM), e.g. to forge a token. Works on Windows too. */
    public static function otherPrivateKeyPem(): string
    {
        $options = ['config' => self::opensslConfig()];
        $key = openssl_pkey_new($options + ['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        openssl_pkey_export($key, $pem, null, $options);

        return $pem;
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
            // Phone verification (SMS) of a signed-in account: the code is always 123456 here.
            'identitytoolkit.googleapis.com/v1/recaptchaParams*' => fn () => Http::response(['recaptchaSiteKey' => 'test-site-key']),
            'identitytoolkit.googleapis.com/v1/accounts:sendVerificationCode*' => fn (Request $r) => $this->sendPhoneCode($r),
            'identitytoolkit.googleapis.com/v1/accounts:signInWithPhoneNumber*' => fn (Request $r) => $this->linkPhone($r),
            'securetoken.googleapis.com/*' => fn (Request $r) => $this->refresh($r),
            'www.googleapis.com/identitytoolkit/v3/relyingparty/getProjectConfig*' => fn () => $this->offline ? Http::failedConnection()
                : Http::response(['projectId' => $this->keyProject ?? self::PROJECT]),
            'www.googleapis.com/robot/*' => fn () => Http::response([self::KID => self::keys()['cert']], 200, ['Cache-Control' => 'public, max-age=3600']),
            'firestore.googleapis.com/*' => fn (Request $r) => $this->firestore($r),
            // The Supabase Edge Function account-email (password reset, e-mail change, MFA notice).
            '*/functions/v1/account-email/*' => fn (Request $r) => $this->accountEmail($r),
        ]);


        return $this;
    }

    /** Numbers already on another Firebase account (linking them is refused). */
    public array $phonesTaken = [];

    /** Numbers an SMS was sent to. */
    public array $phoneCodesSent = [];

    private function sendPhoneCode(Request $r)
    {
        if (($r['recaptchaToken'] ?? '') === '') {
            return Http::response(['error' => ['message' => 'MISSING_RECAPTCHA_TOKEN']], 400);
        }
        $this->phoneCodesSent[] = (string) $r['phoneNumber'];

        return Http::response(['sessionInfo' => 'session-'.$r['phoneNumber']]);
    }

    private function linkPhone(Request $r)
    {
        $phone = substr((string) $r['sessionInfo'], strlen('session-'));
        if ((string) $r['code'] !== '123456') {
            return Http::response(['error' => ['message' => 'INVALID_CODE']], 400);
        }
        if (in_array($phone, $this->phonesTaken, true)) {
            return Http::response(['error' => ['message' => 'PHONE_NUMBER_EXISTS']], 400);
        }
        $parts = explode('.', (string) $r['idToken']);
        $claims = json_decode(base64_decode(strtr($parts[1] ?? '', '-_', '+/')), true) ?: [];
        $uid = (string) ($claims['sub'] ?? '');

        return Http::response([
            'localId' => $uid,
            'idToken' => $this->token($uid, (string) ($claims['email'] ?? ''), (bool) ($claims['email_verified'] ?? false), ['phone_number' => $phone]),
            'refreshToken' => 'refresh-'.$uid,
            'expiresIn' => '3600',
            'phoneNumber' => $phone,
        ]);
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

    /**
     * Points the website at a Supabase project so the account-email function is reachable (the
     * fake above answers it). Not done by install(): a configured project turns the shop on too.
     */
    public function withAccountEmails(): self
    {
        if (blank(config('melai.shop.supabase_url'))) {
            config(['melai.shop.supabase_url' => 'https://account-email.test', 'melai.shop.anon_key' => config('melai.shop.anon_key') ?: 'test-anon-key']);
        }

        return $this;
    }

    /** A link token of the fake account-email function (the real one hashes and stores it). */
    public function issueLink(string $kind, string $email, ?string $newEmail = null): string
    {
        $token = 'link-'.$kind.'-'.count($this->actionLinks).str_repeat('x', 30);
        $this->actionLinks[$token] = ['kind' => $kind, 'email' => mb_strtolower($email), 'new_email' => $newEmail, 'used' => false];

        return $token;
    }

    /** Same answers as supabase/functions/account-email (tested on its own with Deno). */
    private function accountEmail(Request $r)
    {
        $path = (string) parse_url($r->url(), PHP_URL_PATH);
        $route = substr($path, strpos($path, 'account-email/') + strlen('account-email/'));
        $link = function (string $kind) use ($r) {
            $l = $this->actionLinks[(string) $r['token']] ?? null;
            if (! $l || $l['kind'] !== $kind) {
                return [null, Http::response(['code' => 'link_invalid', 'error' => 'invalid'], 400)];
            }

            return $l['used'] ? [null, Http::response(['code' => 'link_used', 'error' => 'used'], 400)] : [$l, null];
        };

        switch ($route) {
            case 'password-reset/request':
                $email = mb_strtolower(trim((string) $r['email']));
                $this->resetEmails[] = $email;
                if (isset($this->accounts[$email])) {
                    $this->issueLink('password_reset', $email);
                }

                return Http::response(['sent' => true]);
            case 'password-reset/check':
                [$l, $err] = $link('password_reset');

                return $err ?? Http::response(['valid' => true, 'email' => $l['email'], 'email_masked' => substr($l['email'], 0, 1).'•••']);
            case 'password-reset/confirm':
                [$l, $err] = $link('password_reset');
                if ($err) {
                    return $err;
                }
                if (strlen((string) $r['password']) < 8) {
                    return Http::response(['code' => 'weak_password', 'error' => 'Password must be at least 8 characters long.'], 422);
                }
                $this->actionLinks[(string) $r['token']]['used'] = true;
                $this->accounts[$l['email']]['password'] = (string) $r['password'];
                $this->accounts[$l['email']]['revoked'] = true;   // validSince: other sign-ins end

                return Http::response(['reset' => true, 'email' => $l['email']]);
            case 'email-change/request':
                $uid = $this->uidFromToken(substr((string) ($r->header('Authorization')[0] ?? ''), 7));
                $this->emailChangeRequests[] = [$uid, mb_strtolower((string) $r['new_email'])];

                return Http::response(['sent' => true, 'message' => 'We sent a confirmation link to '.mb_strtolower((string) $r['new_email']).'. Your email changes after you open it.']);
            case 'email-change/confirm':
            case 'email-change/cancel':
                $kind = $route === 'email-change/confirm' ? 'email_change' : 'email_change_cancel';
                [$l, $err] = $link($kind);
                if ($err) {
                    return $err;
                }
                $this->actionLinks[(string) $r['token']]['used'] = true;
                if ($kind === 'email_change') {
                    $acc = $this->accounts[$l['email']];
                    unset($this->accounts[$l['email']]);
                    $this->accounts[(string) $l['new_email']] = $acc;

                    return Http::response(['changed' => true, 'email' => $l['new_email']]);
                }

                return Http::response(['cancelled' => true]);
            case 'security-notice/mfa-enrolled':
                $this->mfaNotices[] = mb_strtolower((string) $r['email']);

                return Http::response(['sent' => true]);
        }

        return Http::response(['error' => 'Not found.'], 404);
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
        $jwt = substr((string) $r->header('Authorization')[0], 7);
        $caller = $this->uidFromToken($jwt);
        $self = $r->method() === 'GET' && rawurldecode(basename((string) parse_url($r->url(), PHP_URL_PATH))) === $caller;   // read own profile
        // Self-registration (shop / app sign-up): only the caller's OWN customer profile, no branch,
        // and only once the token says the email is verified.
        if (str_ends_with((string) parse_url($r->url(), PHP_URL_PATH), ':commit')) {
            $w = $r['writes'][0] ?? [];
            $target = basename((string) ($w['update']['name'] ?? ''));
            $fields = collect($w['update']['fields'] ?? [])->map(fn ($v) => reset($v))->all();
            $claims = json_decode((string) base64_decode(strtr(explode('.', $jwt)[1] ?? '', '-_', '+/')), true) ?: [];
            $self = $self || ($target === $caller && ($claims['email_verified'] ?? false) === true
                && ($fields['role'] ?? null) === 'customer' && ! isset($fields['branch'])
                && mb_strtolower((string) ($fields['email'] ?? '')) === mb_strtolower((string) ($claims['email'] ?? '')));
        }
        if (! $self && (($this->profiles[$caller]['role'] ?? null) !== 'owner' || ($this->profiles[$caller]['isActive'] ?? true) !== true)) {
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
        if ($r->method() === 'PATCH') {   // update of the fields in updateMask; currentDocument.exists=true
            if (! isset($this->profiles[$uid])) {
                return Http::response(['error' => ['code' => 404, 'status' => 'NOT_FOUND', 'message' => 'No document to update']], 404);
            }
            foreach ((array) $r['fields'] as $k => $v) {
                $this->profiles[$uid][$k] = reset($v);
            }

            return Http::response(['name' => $uid]);
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
