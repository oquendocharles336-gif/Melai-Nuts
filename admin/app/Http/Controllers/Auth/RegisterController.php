<?php

namespace App\Http\Controllers\Auth;

use App\Exceptions\AccountLinkException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Http\Controllers\Controller;
use App\Http\Requests\RegisterRequest;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Auth\AccountLinkStatus;
use App\Services\Auth\AutoLinker;
use App\Services\Auth\FirebaseLogin;
use App\Services\Auth\LinkState;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use App\Services\Firebase\FirebaseTokenVerifier;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * "Create Account" on the website creates (or reuses) a Melai Nuts app account in Firebase
 * Authentication, so the website and the app know the person by the same Firebase UID.
 *
 *  - Email already has an app account and the password is right: the website login is created
 *    from it, but only if the app's staff registry says it is an active owner/staff (FirebaseLogin).
 *  - No app account yet: a new Firebase account is created (accounts:signUp), Firebase emails a
 *    verification link, and the website login waits with NO access and NO staff/owner rights
 *    until an active owner approves it on the Users page (AccountProvisioner::approve).
 *
 * Registering never grants owner rights, and nobody can choose their own role.
 */
class RegisterController extends Controller
{
    public function create()
    {
        return view('auth.register');
    }

    public function store(RegisterRequest $request, FirebaseConfig $config, FirebaseLogin $login, FirebaseAuthClient $client,
        FirebaseTokenVerifier $verifier, FirebaseSession $session, AccountLinkStatus $status)
    {
        $data = $request->validated();
        if (! $config->ready()) {
            throw ValidationException::withMessages(['auth' => $config->missingMessage()]);
        }

        // 1. Does this person already have an app account with this password?
        try {
            [$user, $tokens, $claims] = $login->attempt($data['email'], $data['password']);

            return $this->signIn($request, $user, $tokens, $claims, $session, $status, 'account.created_from_app',
                'You already had a Melai Nuts app account, so your website login uses it.');
        } catch (AccountLinkException $e) {
            throw ValidationException::withMessages(['auth' => $e->getMessage()]);
        } catch (FirebaseAuthException $e) {
            if (! $e->isCredentialError()) {
                throw ValidationException::withMessages(['auth' => $e->getMessage()]);
            }
        }

        // 2. New app account in Firebase Authentication.
        try {
            $tokens = $client->signUp($data['email'], $data['password'], $data['name']);
        } catch (FirebaseAuthException $e) {
            throw ValidationException::withMessages(match ($e->reason) {
                FirebaseAuthException::EMAIL_EXISTS => ['email' => 'A Melai Nuts app account with this email already exists, with a different password. '
                    .'Register with that account\'s password, or use "Forgot password?" on the login page to reset it.'],
                FirebaseAuthException::WEAK_PASSWORD => ['password' => $e->getMessage()],
                FirebaseAuthException::INVALID_EMAIL => ['email' => $e->getMessage()],
                default => ['auth' => $e->getMessage()],
            });
        }

        try {
            $claims = $verifier->verify($tokens['id_token']);
            $user = (new User)->forceFill([
                'name' => $data['name'],
                'email' => $tokens['email'],
                'password' => Hash::make(Str::random(64)), // Firebase holds the real password
                // Role and access are set here, never from the request: no access, no app rights,
                // until an owner approves the registration.
                'role' => User::ROLE_STAFF,
                'is_active' => true,
                'has_access' => false,
                'firebase_uid' => $claims['sub'],
                'firebase_email_verified' => $claims['email_verified'],
            ]);
            $user->save();
        } catch (\Throwable $e) {
            // Never leave a Firebase account without its website login (a retry would hit EMAIL_EXISTS).
            try {
                $client->deleteAccount($tokens['id_token']);
            } catch (\Throwable $rollback) {
                Log::error('[register] could not delete the Firebase account after a failed registration', ['email' => $data['email'], 'error' => $rollback->getMessage()]);
            }
            if ($e instanceof UniqueConstraintViolationException) {
                throw ValidationException::withMessages(['email' => 'An account with this email already exists.']);
            }
            if ($e instanceof FirebaseAuthException) {
                throw ValidationException::withMessages(['auth' => $e->getMessage()]);
            }
            throw $e;
        }

        $sent = true;
        try {
            $client->sendEmailVerification($tokens['id_token']);
        } catch (FirebaseAuthException $e) {
            $sent = false;
            Log::warning('[register] verification email not sent: '.$e->getMessage());
        }

        Auth::login($user);
        $request->session()->regenerate();
        $session->store($tokens, $claims);
        ActivityLogger::log('account.created', "New account created: {$user->email}", $user, [
            'role' => User::ROLE_STAFF, 'firebase_uid' => $claims['sub'], 'verification_email' => $sent,
        ]);

        return redirect()->route('waiting')->with('status', $sent
            ? "Your Melai Nuts app account was created. Firebase sent a verification link to {$user->email}."
            : 'Your Melai Nuts app account was created, but the verification email could not be sent. Use "Resend verification email" below.');
    }

    private function signIn(Request $request, User $user, array $tokens, array $claims, FirebaseSession $session, AccountLinkStatus $status, string $action, string $message)
    {
        if (! $user->is_active) {
            throw ValidationException::withMessages(['auth' => 'This account has been deactivated. Contact an administrator.']);
        }
        try {
            app(AutoLinker::class)->linkAtLogin($user, $claims); // same automatic link as the login page
        } catch (AccountLinkException $e) {
            throw ValidationException::withMessages(['auth' => $e->getMessage()]);
        }
        Auth::login($user);
        $request->session()->regenerate();
        $session->store($tokens, $claims);
        $user->forceFill(['last_login_at' => now()])->save();
        ActivityLogger::log($action, $message, $user, ['firebase_uid' => $claims['sub']]);

        return redirect()->route($user->has_access ? 'dashboard' : 'waiting')->with('status', $message);
    }

    /** "Waiting for access": re-reads the Firebase account (email verified?) and the app registration. */
    public function waiting(Request $request, FirebaseConfig $config, FirebaseSession $session, AccountLinkStatus $status)
    {
        $user = $request->user();
        if ($user->has_access) {
            return redirect()->route('dashboard');
        }

        $state = null;
        if ($user->usesFirebase() && $config->ready()) {
            try {
                $claims = $session->claimsFor($user, forceRefresh: true);
                if ($user->firebase_email_verified !== $claims['email_verified']) {
                    $user->forceFill(['firebase_email_verified' => $claims['email_verified']])->save();
                }
                $state = $status->evaluate($user, $claims, link: true);
                if ($user->fresh()->has_access) {
                    return redirect()->route('dashboard')->with('status', 'An owner approved your account. Welcome!');
                }
            } catch (FirebaseSessionRequiredException $e) {
                $state = ['state' => $e->state, 'message' => $e->getMessage()];
            } catch (BackendUnavailableException $e) {
                $state = ['state' => LinkState::TEMPORARY_ERROR, 'message' => $e->getMessage()];
            }
        }

        return view('auth.waiting', ['user' => $user->fresh(), 'state' => $state]);
    }

    public function resendVerification(Request $request, FirebaseConfig $config, FirebaseSession $session, FirebaseAuthClient $client)
    {
        $user = $request->user();
        abort_unless($user->usesFirebase() && $config->ready(), 404);
        try {
            $client->sendEmailVerification($session->idTokenFor($user));
        } catch (FirebaseSessionRequiredException|FirebaseAuthException $e) {
            return back()->with('error', $e->getMessage());
        }

        return back()->with('status', "Verification link sent to {$user->email}.");
    }
}
