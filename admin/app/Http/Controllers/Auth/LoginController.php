<?php

namespace App\Http\Controllers\Auth;

use App\Exceptions\AccountLinkException;
use App\Http\Controllers\Controller;
use App\Http\Requests\LoginRequest;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Auth\AutoLinker;
use App\Services\Auth\FirebaseLogin;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * Website sign-in. Logging in is all it takes: the login is linked to its staff / owner row in
 * the app's database automatically (AutoLinker) BEFORE the person is signed in, at every sign-in.
 *
 *  - Firebase (the Melai Nuts app email + password), when configured: the UID in the verified ID
 *    token decides the app account.
 *  - Website password (Firebase not configured, or the password is this website's own): the
 *    server finds the row by ADMIN_STAFF_UID (admin) or by the login's email, and Supabase verifies
 *    it AS that UID (active, same email, admin <-> owner, staff <-> staff).
 *
 * When the link is impossible (no matching owner / staff row, inactive account, ...) the reason is
 * shown right here on the login page and nobody is signed in: no one lands on a dead-end page.
 * Passwords are never stored or logged.
 */
class LoginController extends Controller
{
    public function create()
    {
        return view('auth.login');
    }

    public function store(LoginRequest $request, FirebaseConfig $config, FirebaseLogin $firebase, FirebaseSession $session, AutoLinker $linker)
    {
        $request->ensureIsNotRateLimited();
        $email = (string) $request->input('email');
        $firebaseProblem = null;

        if ($config->ready()) {
            try {
                [$user, $tokens, $claims] = $firebase->attempt($email, (string) $request->input('password'));
            } catch (FirebaseAuthException $e) {
                if (in_array($e->reason, [FirebaseAuthException::USER_DISABLED, FirebaseAuthException::TOO_MANY_ATTEMPTS], true)) {
                    $request->failed($e->getMessage());
                }
                $firebaseProblem = $e->isCredentialError() ? null : $e->getMessage();
            } catch (AccountLinkException $e) {
                // Correct app password, but this account may not use the website (reason in the message).
                ActivityLogger::log('auth.login_refused', 'App sign-in refused for '.$email, null, ['state' => $e->state]);
                throw ValidationException::withMessages(['auth' => $e->getMessage()]);
            }

            if (isset($user)) {
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

    /** Shown when a login whose role is not a website role (admin / staff) tries to sign in. */
    public const APP_ONLY_MESSAGE = 'This account cannot use the admin website. Sign in to the Melai Nuts app instead.';

    private function firebaseLogin(LoginRequest $request, User $user, array $tokens, array $claims, FirebaseSession $session, AutoLinker $linker)
    {
        if (! $user->canUseWebsite()) {
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

    public function destroy(Request $request)
    {
        ActivityLogger::log('auth.logout', 'Logged out');
        Auth::logout();
        $request->session()->invalidate(); // also drops the Firebase tokens of this session
        $request->session()->regenerateToken();

        return redirect()->route('landing');
    }

    /** Password reset for app accounts: Firebase emails the reset link. Never says whether the email exists. */
    public function forgot(Request $request, FirebaseConfig $config, FirebaseAuthClient $client)
    {
        $data = $request->validate(['email' => ['required', 'email', 'max:255']]);
        if (! $config->ready()) {
            return back()->with('error', $config->missingMessage());
        }
        try {
            $client->sendPasswordReset(Str::lower(trim($data['email'])));
        } catch (FirebaseAuthException $e) {
            if ($e->reason === FirebaseAuthException::CONFIG || $e->isTemporary()) {
                return back()->withInput()->with('error', $e->getMessage());
            }
        }

        return back()->with('status', 'If a Melai Nuts app account uses that email, Firebase has sent it a password-reset link. The new password works in the app and on this website.');
    }
}
