<?php

namespace App\Services\Auth;

use App\Exceptions\BackendActionException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use App\Services\Firebase\FirebaseTokenVerifier;
use App\Services\Firebase\FirestoreProfiles;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\StaffLinker;
use App\Services\Supabase\SupabaseGateway;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Validation\ValidationException;

/**
 * The owner's app (Firebase) identity for owner actions on app accounts from the website
 * (enable / disable an app account, App\Services\Auth\AppAccountStatus).
 *
 * The website never CREATES or APPROVES staff / owner accounts: those are made only in the
 * Melai Nuts app's User Management (AuthService.createManagedAccount). Customers sign up on the
 * website as customers only (App\Services\Shop\CustomerAccounts).
 */
class AccountProvisioner
{
    public function __construct(
        private FirebaseConfig $config,
        private FirebaseAuthClient $client,
        private FirebaseTokenVerifier $verifier,
        private FirebaseSession $session,
        private FirestoreProfiles $firestore,
        private StaffIdentity $identity,
        private SupabaseGateway $gateway,
        private StaffLinker $linker,
    ) {}

    /** True when the owner must type their app password to register staff (no app sign-in in this session). */
    public function needsOwnerPassword(User $owner): bool
    {
        return ! $this->session->isFor($owner);
    }

    /**
     * The owner's Firebase ID token, needed to write the new person's app profile (firestore.rules
     * let only an owner do that). From this session's app sign-in, or, when the owner signed in with
     * the website password, from their Melai Nuts app password typed on the form ($appPassword).
     * The password is used once and never stored. Problems are form errors: the owner is never
     * signed out of the website because of this.
     */
    public function ownerToken(User $owner, ?string $appPassword): string
    {
        if ($this->session->isFor($owner)) {
            try {
                return $this->session->idTokenFor($owner);
            } catch (FirebaseSessionRequiredException) {
                // app sign-in ended: fall back to the password below
            }
        }
        if (blank($appPassword)) {
            throw ValidationException::withMessages(['owner_password' => 'Enter your Melai Nuts app password to confirm. Changing app accounts is done as your app owner account.']);
        }
        $key = 'owner-app-password:'.$owner->getAuthIdentifier();
        if (RateLimiter::tooManyAttempts($key, 5)) {
            throw ValidationException::withMessages(['owner_password' => 'Too many wrong passwords. Try again in '.RateLimiter::availableIn($key).' seconds.']);
        }
        $ownerUid = $this->requireOwner($owner);
        try {
            $tokens = $this->client->signIn($owner->email, (string) $appPassword);
            $claims = $this->verifier->verify($tokens['id_token']);
        } catch (FirebaseAuthException $e) {
            if (in_array($e->reason, [FirebaseAuthException::INVALID_CREDENTIALS, FirebaseAuthException::ACCOUNT_NOT_FOUND], true)) {
                RateLimiter::hit($key, 300);
                ActivityLogger::log('auth.password_confirm_failed', 'Wrong app password when changing an app account', $owner);
                throw ValidationException::withMessages(['owner_password' => "That is not the Melai Nuts app password of {$owner->email}."]);
            }
            throw ValidationException::withMessages(['owner_password' => $e->getMessage()]);
        }
        if ($claims['sub'] !== $ownerUid) {
            throw ValidationException::withMessages(['owner_password' => "The app account of {$owner->email} is not the owner account this login acts as."]);
        }
        RateLimiter::clear($key);

        return $tokens['id_token'];
    }

    private function requireOwner(User $owner): string
    {
        try {
            $uid = $this->identity->uid($owner);
            if (! $this->identity->isOwner()) {
                throw ValidationException::withMessages(['approve' => 'Only an active owner account can change app accounts.']);
            }
        } catch (BackendActionException $e) {
            throw ValidationException::withMessages(['approve' => $e->getMessage()]);
        }

        return $uid;
    }
}
