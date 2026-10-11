<?php

namespace App\Services\Auth;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
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
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * Registers a Firebase account as Melai Nuts staff / owner, from the website, exactly like the
 * app's User Management screen (AuthService.createManagedAccount) and with the same authority:
 *
 *   1. Supabase staff registry: public.owner_upsert_staff_member, called AS the signed-in owner
 *      (the SQL function itself refuses anyone who is not an active owner);
 *   2. Firestore profile users/{uid}, written with the owner's own ID token (firestore.rules);
 *   3. the website login is linked (StaffLinker re-checks everything in Supabase).
 *
 * A failure after step 1 rolls step 1 back (owner_delete_staff_member, only if the row is new),
 * a failure after step 2 also deletes the Firestore profile, so nothing is left half-registered,
 * and retrying is safe. Owner rights are only ever granted by an active owner doing this.
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

    /** Owner approves a website registration (Firebase account created at registration, email verified). */
    public function approve(User $pending, string $role, ?string $branchId, User $owner): array
    {
        if (blank($pending->firebase_uid) || filled($pending->staff_uid) || ! $pending->canUseWebsite()) {
            throw ValidationException::withMessages(['approve' => 'Only website registrations that are not linked yet can be approved.']);
        }
        if ($pending->is($owner)) {
            throw ValidationException::withMessages(['approve' => 'You cannot approve your own login.']);
        }
        if (! $pending->firebase_email_verified) {
            throw ValidationException::withMessages(['approve' => "{$pending->email} has not verified their email yet. They must click the link Firebase emailed them and then sign in once (or press \"Check again\" on their waiting page)."]);
        }

        return $this->provision($pending, $role, $branchId, $owner);
    }

    /**
     * Admin creates a staff account on the website: new Firebase account + app registration + linked
     * login, all or nothing. @return array [User, profile]
     */
    public function createStaff(string $name, string $email, string $password, ?string $branchId, User $owner): array
    {
        $this->requireOwner($owner); // before anything is created in Firebase
        try {
            $tokens = $this->client->signUp($email, $password, $name);
        } catch (FirebaseAuthException $e) {
            throw ValidationException::withMessages([$e->reason === FirebaseAuthException::EMAIL_EXISTS ? 'email' : 'password' => match ($e->reason) {
                FirebaseAuthException::EMAIL_EXISTS => 'This email already has a Melai Nuts app account. If it is this person\'s, ask them to sign in to the website with it (or use Create Account there) and approve them on this page; otherwise use another email.',
                default => $e->getMessage(),
            }]);
        }

        $user = null;
        try {
            $claims = $this->verifier->verify($tokens['id_token']);
            $user = (new User)->forceFill([
                'name' => $name, 'email' => $tokens['email'], 'password' => Hash::make(Str::random(64)),
                'role' => User::ROLE_STAFF, 'is_active' => true, 'has_access' => false,
                'firebase_uid' => $claims['sub'], 'firebase_email_verified' => $claims['email_verified'],
            ]);
            $user->save();
            $profile = $this->provision($user, 'staff', $branchId, $owner);

            return [$user->fresh(), $profile];
        } catch (\Throwable $e) {
            $user?->exists && $user->delete();
            try {
                $this->client->deleteAccount($tokens['id_token']);
            } catch (\Throwable $rollback) {
                Log::error('[provision] could not delete the new Firebase account after a failed creation', ['email' => $email, 'error' => $rollback->getMessage()]);
            }
            if ($e instanceof UniqueConstraintViolationException) {
                throw ValidationException::withMessages(['email' => 'A website login with this email already exists.']);
            }
            if ($e instanceof FirebaseAuthException) {
                throw ValidationException::withMessages(['email' => $e->getMessage()]);
            }
            throw $e;
        }
    }

    private function provision(User $user, string $role, ?string $branchId, User $owner): array
    {
        if (! in_array($role, ['staff', 'owner'], true)) {
            throw ValidationException::withMessages(['role' => 'Choose Staff or Owner.']);
        }
        $ownerUid = $this->requireOwner($owner);
        $branchName = null;
        if ($role === 'staff') {
            $branch = collect($this->identity->branches())->firstWhere('id', $branchId);
            if (! $branch) {
                throw ValidationException::withMessages(['branch_id' => 'Choose one of your branches for this staff member.']);
            }
            $branchName = $branch['name'];
        }
        $uid = $user->firebase_uid;
        $ownerToken = $this->session->idTokenFor($owner);

        $existed = ($this->identity->contextFor($uid)['status'] ?? 'not_provisioned') !== 'not_provisioned';
        $this->identity->forget($uid);

        // 1. Supabase staff registry, as the owner.
        $this->gateway->call($ownerUid, 'select public.owner_upsert_staff_member(?, ?, ?, ?, ?, true, true, false)::text as r',
            [$uid, $user->name, $user->email, $role, $branchName]);
        $this->identity->forget($uid);

        // 2. Firestore profile, as the owner.
        $created = false;
        try {
            // An existing profile (e.g. from an earlier, interrupted approval) is reused only if its role matches;
            // checking first avoids the rules treating the create as an update of someone else's profile.
            $doc = $this->firestore->get($ownerToken, $uid);
            if ($doc === null) {
                $created = $this->firestore->create($ownerToken, $uid, $user->email, $user->name, $role, $branchName) === 'created';
                $doc = $created ? null : $this->firestore->get($ownerToken, $uid);
            }
            if ($doc !== null && ($doc['role'] ?? null) !== $role) {
                throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED,
                    'This app account already has an app profile with role "'.($doc['role'] ?? '?').'". Change it in the app\'s User Management instead.');
            }

            // 3. Link the website login (verified again by Supabase).
            $previousRole = $user->role;
            $user->forceFill(['role' => $role === 'owner' ? User::ROLE_ADMIN : User::ROLE_STAFF])->save();
            try {
                $profile = $this->linker->link($user, $uid, $owner);
            } catch (\Throwable $e) {
                $user->forceFill(['role' => $previousRole])->save();
                throw $e;
            }
        } catch (\Throwable $e) {
            $this->rollback($ownerUid, $ownerToken, $uid, $existed, $created);
            if ($e instanceof FirebaseAuthException) {
                throw ValidationException::withMessages(['approve' => $e->getMessage().' Nothing was registered; you can try again.']);
            }
            throw $e;
        }

        $user->forceFill(['has_access' => true])->save();
        ActivityLogger::log('account.provisioned', "{$owner->email} registered {$user->email} as app {$role}".($branchName ? " ({$branchName})" : ''), $owner, [
            'user_id' => $user->id, 'firebase_uid' => $uid, 'role' => $role, 'branch' => $branchName,
        ]);

        return $profile;
    }

    /** The owner's UID, after checking (in Supabase, with their Firebase session) that they are an active owner. */
    private function requireOwner(User $owner): string
    {
        try {
            $uid = $this->identity->uid($owner);
            if (! $this->identity->isOwner()) {
                throw ValidationException::withMessages(['approve' => 'Only an active owner account can register staff.']);
            }
        } catch (BackendActionException $e) {
            throw ValidationException::withMessages(['approve' => $e->getMessage()]);
        }

        return $uid;
    }

    private function rollback(string $ownerUid, string $ownerToken, string $uid, bool $existed, bool $createdDoc): void
    {
        if (! $existed) {
            try {
                $this->gateway->call($ownerUid, 'select public.owner_delete_staff_member(?)::text as r', [$uid]);
            } catch (BackendActionException|BackendUnavailableException $e) {
                Log::error('[provision] rollback of staff_members row failed; retry the approval or remove it in the app', ['uid' => $uid, 'error' => $e->getMessage()]);
            }
        }
        if ($createdDoc) {
            try {
                $this->firestore->delete($ownerToken, $uid);
            } catch (\Throwable $e) {
                Log::error('[provision] rollback of Firestore profile failed', ['uid' => $uid, 'error' => $e->getMessage()]);
            }
        }
        $this->identity->forget($uid);
    }
}
