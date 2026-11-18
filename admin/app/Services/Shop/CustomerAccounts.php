<?php

namespace App\Services\Shop;

use App\Http\Requests\Rules;
use App\Services\Auth\EmailCodeException;
use App\Services\Auth\EmailCodes;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseTokenVerifier;
use App\Services\Firebase\FirestoreProfiles;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\Log;

/**
 * Shop sign-in and sign-up with the SAME Firebase account the Melai Nuts app uses.
 *
 * It follows the app's own steps (lib/core/services/auth_service.dart), so an account made in
 * either place works in the other:
 *   sign-up  = Firebase account -> 6-digit email code (Melai Nuts' own e-mail, sent and checked by
 *              the Supabase Edge Function email-verification, with a Turnstile check; Firebase's
 *              verification link is never used) -> Firestore users/{uid} with
 *              role "customer" (allowed by firestore.rules only once the email is verified)
 *              -> Supabase customer_profiles row -> Terms accepted (accept_legal_terms).
 *   sign-in  = Firebase password check -> Firestore users/{uid} must say role "customer" and
 *              active (staff, owners and riders are sent to their own sign-in) -> profile.
 */
class CustomerAccounts
{
    /** A sign-up waiting for its email code, kept in the session between pages. */
    public const PENDING = 'shop_pending_signup';

    public function __construct(
        private FirebaseAuthClient $firebase,
        private FirebaseTokenVerifier $verifier,
        private FirestoreProfiles $firestore,
        private SupabaseRest $rest,
        private CustomerSession $session,
        private EmailCodes $codes,
    ) {}

    /**
     * Sign a customer in. Returns 'signed_in', or 'verify' when the account still has to confirm
     * its email (the pending sign-up is then kept in the session).
     *
     * @throws ShopException
     */
    public function signIn(string $email, string $password): string
    {
        $tokens = $this->firebase(fn () => $this->firebase->signIn(trim($email), $password));
        $claims = $this->verify($tokens['id_token']);
        $profile = $this->firebase(fn () => $this->firestore->get($tokens['id_token'], $claims['sub']));

        return $this->signInWith($tokens, $claims, $profile);
    }

    /**
     * Finish a customer sign-in for an account the single login (/login) already signed in with
     * Firebase and read the profile of. Returns 'signed_in' or 'verify'.
     *
     * @throws ShopException
     */
    public function signInWith(array $tokens, array $claims, ?array $profile): string
    {
        if ($profile === null) {
            // Created a Firebase account (app or website) but never finished the email step.
            $this->keepPending($tokens, $claims, (string) ($claims['claims']['name'] ?? ''), '');
            if (! $claims['email_verified']) {
                // The code is sent from the verify page, after its security check.
                return 'verify';
            }

            $this->completeSignUp();

            return 'signed_in';
        }

        $this->assertCustomer($profile);
        $name = trim((string) ($profile['name'] ?? '')) ?: 'Customer';
        $phone = (string) ($profile['phone'] ?? '');
        $this->session->start($tokens, $claims, $name, $phone);
        $this->ensureSupabaseProfile($name, $claims['email'] ?? '', $phone);

        return 'signed_in';
    }

    /**
     * Step 1 of sign-up: create the Firebase account and email the 6-digit code (with the sign-up
     * form's security-check token). The account exists from here on, so a code that could not be
     * sent is not an error of the form: the returned note is shown on the verify page, where the
     * customer can send it again. Null = the code is on its way.
     *
     * @throws ShopException when the account itself could not be created
     */
    public function startSignUp(string $name, string $email, string $phone, string $password, bool $orderUpdates, ?string $captchaToken = null): ?string
    {
        $tokens = $this->firebase(fn () => $this->firebase->signUp(trim($email), $password, $name));
        $claims = $this->verify($tokens['id_token']);
        $this->keepPending($tokens, $claims, $name, (string) Rules::normalizePhone($phone), $orderUpdates);
        try {
            $this->codes->send($tokens['id_token'], $captchaToken);
            $this->markCodeSent();

            return null;
        } catch (EmailCodeException $e) {
            return $e->needsCaptcha() ? 'Complete the security check below and we\'ll email you a 6-digit code.' : $e->getMessage();
        }
    }

    /** True once a code was emailed for the pending sign-up. */
    public function pendingCodeSent(): bool
    {
        $p = session(self::PENDING);

        return is_array($p) && ($p['code_sent'] ?? false) === true;
    }

    public function pendingEmail(): ?string
    {
        $p = session(self::PENDING);

        return is_array($p) ? (string) $p['email'] : null;
    }

    /** (Re)send the 6-digit code for the pending sign-up; needs a security-check token. @throws ShopException */
    public function resendVerification(?string $captchaToken): void
    {
        $p = $this->pending();
        $s = $this->refreshPending($p);
        $this->code(fn () => $this->codes->send($s['id_token'], $captchaToken));
        $this->markCodeSent();
    }

    /**
     * Step 2 of sign-up: check the 6-digit code (with its security check, verified by the server
     * FIRST), refresh the token so it says email_verified, then create the Firestore profile, the
     * Supabase profile and the Terms record, and sign the customer in. Without a code, only an
     * account that is already verified goes through (sign-in of an unfinished sign-up).
     *
     * @throws ShopException reason "unverified" when no code was given and the email is not verified
     */
    public function completeSignUp(?string $code = null, ?string $captchaToken = null): void
    {
        $p = $this->pending();
        $p = $this->refreshPending($p);
        $claims = $this->verify($p['id_token']);
        if (! $claims['email_verified']) {
            if ($code === null) {
                throw new ShopException('Your email isn\'t verified yet. Enter the 6-digit code we emailed you.', 'unverified');
            }
            $this->code(fn () => $this->codes->verify($p['id_token'], $code, $captchaToken));
            // email_verified only changes in a NEW token.
            $p = $this->refreshPending($p);
            $claims = $this->verify($p['id_token']);
            if (! $claims['email_verified']) {
                throw new ShopException('We couldn\'t confirm your email yet. Please try again in a moment.', 'unverified');
            }
        }

        $name = trim($p['name']) !== '' ? trim($p['name']) : 'Customer';
        $result = $this->firebase(fn () => $this->firestore->create(
            $p['id_token'], $claims['sub'], (string) $claims['email'], $name, 'customer', null, $p['phone'] !== '' ? $p['phone'] : null,
        ));
        if ($result === 'exists') {
            $profile = $this->firebase(fn () => $this->firestore->get($p['id_token'], $claims['sub']));
            $this->assertCustomer($profile ?? []);
        }

        $tokens = ['id_token' => $p['id_token'], 'refresh_token' => Crypt::decryptString($p['refresh_token']), 'expires_in' => max(60, $p['expires_at'] - time())];
        $this->session->start($tokens, $claims, $name, $p['phone']);
        session()->forget(self::PENDING);

        $this->ensureSupabaseProfile($name, (string) $claims['email'], $p['phone']);
        $this->acceptTerms($p['order_updates'] ?? null);
    }

    public function cancelSignUp(): void
    {
        session()->forget(self::PENDING);
    }

    /** True when the signed-in customer has accepted the current Terms and Privacy Policy. */
    public function hasAcceptedCurrentTerms(): bool
    {
        try {
            $row = $this->rest->rpc('my_legal_acceptance', [], $this->session->idToken());
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                throw $e;
            }

            return true; // can't check right now: never block the customer on it
        }

        return is_array($row)
            && ($row['terms_version'] ?? null) === config('melai.legal.terms_version')
            && ($row['privacy_version'] ?? null) === config('melai.legal.privacy_version');
    }

    /** Record acceptance of the current Terms and Privacy Policy (same call as the app). */
    public function acceptTerms(?bool $orderUpdates = null): void
    {
        try {
            $this->rest->rpc('accept_legal_terms', [
                'p_terms_version' => (string) config('melai.legal.terms_version'),
                'p_privacy_version' => (string) config('melai.legal.privacy_version'),
                'p_order_updates' => $orderUpdates,
            ], $this->session->idToken());
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                throw $e;
            }
            Log::warning('[shop] terms acceptance not saved', ['reason' => $e->reason]);
        }
    }

    /** Send a password-reset email (never says whether the email has an account). */
    public function sendPasswordReset(string $email): void
    {
        try {
            app(\App\Services\Auth\AccountEmails::class)->requestPasswordReset(trim($email), request()?->ip());
        } catch (\App\Services\Auth\AccountEmailException $e) {
            if ($e->reason !== 'cooldown') {   // a repeat within a minute: the first email is on its way
                throw new ShopException($e->getMessage(), $e->reason === 'offline' ? 'offline' : 'refused');
            }
        }
    }

    /**
     * The customer_profiles row the app creates on first sign-in (CustomerProfileRepository.ensureProfile):
     * the registration phone goes in so checkout has a contact number. Best effort, like the app.
     */
    public function ensureSupabaseProfile(string $name, string $email, string $phone): void
    {
        try {
            $token = $this->session->idToken();
            $uid = (string) $this->session->uid();
            $rows = $this->rest->select('customer_profiles', ['select' => 'firebase_uid,full_name,phone', 'firebase_uid' => 'eq.'.$uid], $token);
            if ($rows === []) {
                $this->rest->insert('customer_profiles', array_filter([
                    'firebase_uid' => $uid,
                    'full_name' => $name,
                    'email' => $email,
                    'phone' => trim($phone) !== '' ? trim($phone) : null,
                ], fn ($v) => $v !== null), $token);
            } elseif (trim((string) ($rows[0]['phone'] ?? '')) === '' && trim($phone) !== '') {
                $this->rest->update('customer_profiles', ['firebase_uid' => 'eq.'.$uid], ['phone' => trim($phone)], $token);
            } elseif (trim((string) ($rows[0]['phone'] ?? '')) !== '') {
                $this->session->rememberPhone((string) $rows[0]['phone']);
            }
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                throw $e;
            }
            Log::warning('[shop] customer profile not ensured', ['reason' => $e->reason]);
        }
    }

    // ------------------------------------------------------------------------------------------

    /** Only customer accounts may use the shop (staff, owners and riders have their own sign-in). */
    private function assertCustomer(array $profile): void
    {
        $role = (string) ($profile['role'] ?? '');
        if ($role !== 'customer') {
            throw new ShopException(
                $role === 'delivery'
                    ? 'This is a rider account. Riders use the Melai Nuts app.'
                    : 'This is a staff account. Please use the staff sign-in instead.',
                'not_customer',
            );
        }
        if (($profile['isActive'] ?? true) === false) {
            throw new ShopException('This account has been deactivated. Please contact Melai Nuts for help.', 'not_customer');
        }
    }

    private function markCodeSent(): void
    {
        $p = session(self::PENDING);
        if (is_array($p)) {
            session()->put(self::PENDING, array_merge($p, ['code_sent' => true]));
        }
    }

    /** E-mail code errors become customer-facing ShopExceptions (reason "captcha" = redo the check). */
    private function code(\Closure $call): mixed
    {
        try {
            return $call();
        } catch (EmailCodeException $e) {
            throw new ShopException($e->getMessage(), $e->sessionEnded() ? 'session' : ($e->needsCaptcha() ? 'captcha' : 'refused'), previous: $e);
        }
    }

    private function keepPending(array $tokens, array $claims, string $name, string $phone, ?bool $orderUpdates = null): void
    {
        session()->put(self::PENDING, [
            'uid' => $claims['sub'],
            'email' => (string) ($claims['email'] ?? $tokens['email'] ?? ''),
            'name' => $name,
            'phone' => $phone,
            'order_updates' => $orderUpdates,
            'id_token' => $tokens['id_token'],
            'refresh_token' => Crypt::encryptString($tokens['refresh_token']),
            'expires_at' => time() + max(60, (int) ($tokens['expires_in'] ?? 3600)),
        ]);
    }

    private function pending(): array
    {
        $p = session(self::PENDING);
        if (! is_array($p)) {
            throw new ShopException('Your sign-up session expired. Please create your account again or sign in.', 'session');
        }

        return $p;
    }

    /** Always refresh: the email_verified claim only changes in a NEW token. */
    private function refreshPending(array $p): array
    {
        $t = $this->firebase(fn () => $this->firebase->refresh(Crypt::decryptString($p['refresh_token'])));
        if ($t['uid'] !== $p['uid']) {
            throw new ShopException('Your sign-up session expired. Please sign in again.', 'session');
        }
        $p = array_merge($p, [
            'id_token' => $t['id_token'],
            'refresh_token' => Crypt::encryptString($t['refresh_token'] ?: Crypt::decryptString($p['refresh_token'])),
            'expires_at' => time() + max(60, $t['expires_in']),
        ]);
        session()->put(self::PENDING, $p);

        return $p;
    }

    private function verify(string $idToken): array
    {
        return $this->firebase(fn () => $this->verifier->verify($idToken));
    }

    /** Firebase errors become customer-facing ShopExceptions (wording close to the app's). */
    private function firebase(\Closure $call): mixed
    {
        try {
            return $call();
        } catch (FirebaseAuthException $e) {
            throw new ShopException(match ($e->reason) {
                FirebaseAuthException::INVALID_CREDENTIALS, FirebaseAuthException::ACCOUNT_NOT_FOUND => 'The email or password is incorrect.',
                FirebaseAuthException::EMAIL_EXISTS => 'An account already exists with this email. Please sign in instead.',
                FirebaseAuthException::WEAK_PASSWORD => 'Please choose a stronger password.',
                FirebaseAuthException::INVALID_EMAIL => 'Please enter a valid email address.',
                FirebaseAuthException::USER_DISABLED => 'This account has been deactivated. Please contact Melai Nuts for help.',
                FirebaseAuthException::TOO_MANY_ATTEMPTS => 'Too many attempts. Please wait a few minutes and try again.',
                FirebaseAuthException::NETWORK => 'We couldn\'t reach the sign-in service. Please try again in a moment.',
                FirebaseAuthException::SESSION_ENDED => 'Your sign-in has ended. Please sign in again.',
                default => 'We couldn\'t sign you in right now. Please try again.',
            }, match ($e->reason) {
                FirebaseAuthException::NETWORK => 'offline',
                FirebaseAuthException::SESSION_ENDED => 'session',
                default => 'refused',
            }, previous: $e);
        }
    }
}
