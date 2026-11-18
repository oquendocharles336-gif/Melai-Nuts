<?php

namespace App\Http\Controllers\Auth;

use App\Exceptions\AccountLinkException;
use App\Http\Controllers\Controller;
use App\Http\Requests\LoginRequest;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Http\Controllers\Shop\CustomerAuthController;
use App\Services\Auth\AccountKind;
use App\Services\Auth\AccountEmailException;
use App\Services\Auth\AccountEmails;
use App\Services\Auth\AutoLinker;
use App\Services\Auth\FirebaseLogin;
use App\Services\Auth\SignInGuard;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use App\Services\Firebase\FirebaseTokenVerifier;
use App\Services\Shop\CustomerAccounts;
use App\Services\Shop\CustomerSession;
use App\Services\Shop\ShopException;
use App\Support\AuthPanel;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * THE sign-in for the website (customers and the owner), with the Melai Nuts app account.
 * One Firebase sign-in, then the ACCOUNT decides the side (AccountKind, from its Firestore role):
 * customers go to the shop with their own shop session (never an admin login, never the admin
 * steps below); owners go through the admin steps below to the dashboard; staff and riders are
 * refused: they sign in to the Melai Nuts app only.
 *
 * Admin sign-in. Logging in is all it takes: the login is linked to its staff / owner row in
 * the app's database automatically (AutoLinker) BEFORE the person is signed in, at every sign-in.
 *
 *  - Firebase (the Melai Nuts app email + password), when configured: the UID in the verified ID
 *    token decides the app account.
 *  - Website password (Firebase not configured, or the password is this website's own): the
 *    server finds the row by ADMIN_STAFF_UID (admin) or by the login's email, and Supabase verifies
 *    it AS that UID (active, same email, admin <-> owner, staff <-> staff).
 *
 * When the link is impossible (no matching owner / staff row, inactive account, ...) the reason is
 * shown right in the sign-in panel and nobody is signed in: no one lands on a dead-end page.
 *
 * There is no separate sign-in page: the form is the sign-in panel on the shop homepage
 * (AuthPanel). /login, and every "please sign in" redirect that goes through it, opens that panel.
 * Passwords are never stored or logged.
 */
class LoginController extends Controller
{
    /** /login opens the homepage with the sign-in panel (messages such as "please sign in" come along). */
    public function create(Request $request, CustomerSession $customer)
    {
        if ($customer->check()) {
            return redirect()->route('shop.home');
        }
        $request->session()->reflash();

        return redirect()->to(AuthPanel::url(AuthPanel::SIGN_IN));
    }

    public function store(LoginRequest $request, FirebaseConfig $config, FirebaseLogin $firebase, FirebaseSession $session, AutoLinker $linker,
        FirebaseAuthClient $client, FirebaseTokenVerifier $verifier, AccountKind $kinds, CustomerAccounts $customers)
    {
        $request->ensureIsNotRateLimited();
        $email = (string) $request->input('email');
        $firebaseProblem = null;

        if ($config->ready()) {
            // Server-side sign-in counter (shared with the app): after 15 attempts for this email
            // or this visitor's IP in 30 minutes, a security check is needed. A gate, not a lockout.
            $guard = app(SignInGuard::class);
            $gate = $guard->precheck($email, $request->ip(), $this->captchaToken($request));
            if ($gate !== SignInGuard::PROCEED) {
                session()->flash('auth_captcha_required', true);
                throw AuthPanel::back(ValidationException::withMessages(['auth' => $gate === SignInGuard::CAPTCHA_REQUIRED
                    ? 'For your security, please complete the security check, then sign in again.'
                    : 'The security check expired or failed. Please do it again, then sign in.']), AuthPanel::SIGN_IN);
            }
            if ($guard->captchaWasNeeded) {
                session()->flash('auth_captcha_required', true);   // a wrong password now: the check stays shown
            }
            try {
                $tokens = $client->signIn($email, (string) $request->input('password'));
                $guard->succeeded($tokens['id_token']);
                $claims = $verifier->verify($tokens['id_token']);
                [$kind, $profile] = $kinds->of($tokens['id_token'], $claims);
                if ($kind === AccountKind::RIDER) {
                    ActivityLogger::log('auth.login_refused', 'Rider account tried to log in to the website', null, ['uid' => $claims['sub']]);
                    $request->failed('This is a rider account. Riders use the Melai Nuts app.');
                }
                if ($kind === AccountKind::CUSTOMER || $kind === AccountKind::NEW_CUSTOMER) {
                    return $this->customerLogin($request, $tokens, $claims, $profile, $customers);
                }
                // Staff never use the website, whatever the password: the app only.
                if (($profile['role'] ?? null) === 'staff') {
                    ActivityLogger::log('auth.login_refused', 'Staff account tried to log in to the website', null, ['uid' => $claims['sub']]);
                    $request->failed(self::APP_ONLY_MESSAGE);
                }
                // Owner: the admin steps (link, two-step).
                $user = $firebase->resolveUser($claims, $email);
            } catch (FirebaseAuthException $e) {
                if (in_array($e->reason, [FirebaseAuthException::USER_DISABLED, FirebaseAuthException::TOO_MANY_ATTEMPTS], true)) {
                    $request->failed($e->getMessage());
                }
                $firebaseProblem = $e->isCredentialError() ? null : $e->getMessage();
            } catch (AccountLinkException $e) {
                // Correct app password, but this account may not use the website (reason in the message).
                ActivityLogger::log('auth.login_refused', 'App sign-in refused for '.$email, null, ['state' => $e->state]);
                throw AuthPanel::back(ValidationException::withMessages(['auth' => $e->getMessage()]), AuthPanel::SIGN_IN);
            }

            if (isset($user)) {
                $request->session()->forget(CustomerSession::KEY);   // one account per session
                return $this->firebaseLogin($request, $user, $tokens, $claims, $session, $linker);
            }
        }

        // Local password: only logins that are not bound to a Firebase account.
        if ($request->authenticateLocally()) {
            return $this->localLogin($request, $linker);
        }
        if ($firebaseProblem !== null) {
            $request->failed($firebaseProblem);
        }
        if (! $config->ready() && User::where('email', $email)->whereNotNull('firebase_uid')->exists()) {
            $request->failed($config->missingMessage());
        }
        $request->failed('Invalid email or password. Use your Melai Nuts app email and password.');
    }

    /** The Turnstile token of the sign-in form, if the widget was shown. */
    private function captchaToken(Request $request): ?string
    {
        $t = $request->input('cf-turnstile-response');

        return is_string($t) && $t !== '' && strlen($t) <= 2048 ? $t : null;
    }

    /** A customer account: the shop (guest cart added, Terms checked), with its own shop session. */
    private function customerLogin(LoginRequest $request, array $tokens, array $claims, ?array $profile, CustomerAccounts $customers)
    {
        try {
            $result = $customers->signInWith($tokens, $claims, $profile);
        } catch (ShopException $e) {
            $request->failed($e->getMessage());
        }
        $request->succeeded();
        if ($result === 'verify') {
            return redirect()->route('shop.verify')->with('shop_status', 'Please verify your email first: complete the security check and we\'ll email you a 6-digit code.');
        }

        return app(CustomerAuthController::class)->afterSignIn($request, 'Welcome back, '.app(CustomerSession::class)->firstName().'!');
    }

    /** Shown when a login whose role is not the website role (owner / admin) tries to sign in. */
    public const APP_ONLY_MESSAGE = 'Staff accounts cannot sign in on the website. Please sign in to the Melai Nuts app instead.';

    private function firebaseLogin(LoginRequest $request, User $user, array $tokens, array $claims, FirebaseSession $session, AutoLinker $linker)
    {
        // A "staff" login goes on to the linker: it is refused there too, unless the app's staff
        // registry says its account is an active owner now (then it becomes an admin login).
        if (! $user->canUseWebsite() && $user->role !== User::ROLE_STAFF) {
            ActivityLogger::log('auth.login_refused', 'App-only account tried to log in to the website', $user, ['role' => $user->role]);
            $request->failed(self::APP_ONLY_MESSAGE);
        }
        if (! $user->is_active) {
            ActivityLogger::log('auth.login_blocked', 'Deactivated account tried to log in', $user);
            $request->failed('This account has been deactivated. Contact an administrator.');
        }

        // Link to the staff / owner row first: if that is impossible, nobody is signed in.
        try {
            $linker->linkAtLogin($user, $claims);
        } catch (AccountLinkException $e) {
            $request->failed($e->getMessage());
        }

        Auth::login($user, $request->boolean('remember'));
        $request->session()->regenerate(); // prevents session fixation
        $session->store($tokens, $claims);  // the password itself is never stored
        $request->succeeded();
        $user->forceFill(['last_login_at' => now()])->save();
        ActivityLogger::log('auth.login', 'Logged in with the Melai Nuts app account', $user, ['method' => 'firebase']);

        return $user->has_access ? redirect()->intended(route('dashboard')) : redirect()->route('waiting');
    }

    private function localLogin(LoginRequest $request, AutoLinker $linker)
    {
        $user = Auth::user();
        $refuse = function (string $message) use ($request) {
            Auth::logout();
            $request->session()->invalidate();
            $request->session()->regenerateToken();
            $request->failed($message);
        };

        if (! $user->canUseWebsite()) {
            ActivityLogger::log('auth.login_refused', 'App-only account tried to log in to the website', $user, ['role' => $user->role]);
            $refuse(self::APP_ONLY_MESSAGE);
        }
        if (! $user->is_active) {
            ActivityLogger::log('auth.login_blocked', 'Deactivated account tried to log in', $user);
            $refuse('This account has been deactivated. Contact an administrator.');
        }

        // Same automatic link as the Firebase path, decided on the server and verified by Supabase.
        try {
            $linker->linkAtLogin($user->fresh() ?? $user, null);
        } catch (AccountLinkException $e) {
            $refuse($e->getMessage());
        }
        $user->refresh();

        $request->succeeded();
        $request->session()->regenerate(); // prevents session fixation
        $user->forceFill(['last_login_at' => now()])->save();
        ActivityLogger::log('auth.login', 'Logged in', $user, ['method' => 'local']);

        return $user->has_access ? redirect()->intended(route('dashboard')) : redirect()->route('waiting');
    }

    /** ONE logout for everything: the admin login, the shop sign-in and both Firebase sessions. */
    public function destroy(Request $request)
    {
        if (Auth::check()) {
            ActivityLogger::log('auth.logout', 'Logged out');
        }
        Auth::logout();
        $request->session()->invalidate(); // drops the admin login, the shop sign-in and every token of this session
        $request->session()->regenerateToken();

        return redirect()->route('shop.home')->with('shop_status', "You're signed out.");
    }

    /**
     * Settings > "Send me a reset email": the signed-in person's own app account gets a password-reset
     * link (our own e-mail and single-use link, account-email function). Only ever their own email.
     */
    public function sendMyReset(Request $request, AccountEmails $emails)
    {
        $user = $request->user();
        $back = redirect()->route('settings');
        if (! $user->usesFirebase()) {
            return $back->with('error', 'This login uses a website password, not a Melai Nuts app account, so there is no reset email. Ask an administrator to reset it.');
        }
        try {
            $emails->requestPasswordReset((string) $user->email, $request->ip());
        } catch (AccountEmailException $e) {
            return $back->with('error', $e->reason === 'cooldown' || $e->reason === 'hourly_limit' ? $e->getMessage() : 'We couldn\'t send the email right now. Please try again in a moment.');
        }
        ActivityLogger::log('auth.password_reset_requested', 'Asked for a password-reset email from Settings', $user);

        return $back->with('status', "We've sent a password-reset link to {$user->email}. The new password works in the app and on this website.");
    }

    /** Password reset for app accounts: we email the reset link. Never says whether the email exists. */
    public function forgot(Request $request, AccountEmails $emails)
    {
        $data = $request->validate(['email' => ['required', 'email', 'max:255']]);
        $panel = redirect()->to(AuthPanel::url(AuthPanel::RESET_PASSWORD));
        try {
            $emails->requestPasswordReset(Str::lower(trim($data['email'])), $request->ip());
        } catch (AccountEmailException $e) {
            if ($e->reason !== 'cooldown') {   // a repeat within a minute gets the same note (the first email is on its way)
                return $panel->withInput()->with('error', $e->getMessage());
            }
        }

        return redirect()->to(AuthPanel::url(AuthPanel::SIGN_IN))->with('status', 'If a Melai Nuts account uses that email, we\'ve sent it a password-reset link. The new password works in the app and on this website.');
    }
}
