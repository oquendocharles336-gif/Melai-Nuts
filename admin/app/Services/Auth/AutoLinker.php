<?php

namespace App\Services\Auth;

use App\Exceptions\AccountLinkException;
use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Platform;
use App\Services\Supabase\StaffLinker;
use App\Services\Supabase\SupabaseGateway;
use Illuminate\Validation\ValidationException;

/**
 * Links a website login to its Melai Nuts app account (staff_members row) automatically, every
 * time the person signs in. Nobody links anything by hand, and a missing or changed link repairs
 * itself at the next sign-in.
 *
 * Which staff_members row:
 *  - Signed in with Firebase (app email + password): the UID in the verified ID token, nothing else
 *    (AccountLinkStatus::evaluate, as before).
 *  - Signed in with the website password (linkServerSide):
 *      1. a login bound to a Firebase account: that account's UID only;
 *      2. otherwise the current users.staff_uid, if it still checks out;
 *      3. the admin login: ADMIN_STAFF_UID from .env;
 *      4. the active row whose e-mail equals the login's e-mail, with the role that fits the login
 *         (website admin -> owner, website staff -> staff).
 *    Every candidate is VERIFIED by asking Supabase AS that UID (get_my_staff_context via
 *    SupabaseGateway::actingAs, so RLS and the SQL role checks apply): active, same e-mail, right
 *    role, not linked to another login. Only then users.staff_uid is saved.
 *
 * If no candidate passes, the sign-in is refused with the exact reason (AccountLinkException),
 * shown on the login page. Exception: a website registration still waiting for an owner's
 * approval is signed in to the "Waiting for access" page, as before. Logins whose role may not use
 * the website (old rider logins) are refused.
 */
class AutoLinker
{
    public function __construct(
        private Platform $platform,
        private AccountLinkStatus $status,
        private StaffLinker $linker,
        private SupabaseGateway $gateway,
    ) {}

    /**
     * @param  array|null  $claims  verified Firebase ID-token claims, or null for a website-password sign-in
     * @return array ['state' => LinkState::*, 'message' => string, 'profile' => ?array]
     * @throws AccountLinkException
     */
    public function linkAtLogin(User $user, ?array $claims = null): array
    {
        if (! $user->canUseWebsite()) {
            throw new AccountLinkException(LinkState::ROLE_NOT_AUTHORIZED, \App\Http\Controllers\Auth\LoginController::APP_ONLY_MESSAGE);
        }
        if (! $this->platform->isSupabase()) {
            return ['state' => LinkState::NOT_APPLICABLE, 'message' => '', 'profile' => null];
        }

        return $claims === null ? $this->linkServerSide($user) : $this->linkWithFirebase($user, $claims);
    }

    private function linkWithFirebase(User $user, array $claims): array
    {
        $wasLinked = filled($user->staff_uid);
        $wasRole = $user->role;
        $result = $this->status->evaluate($user, $claims, link: true, promoteOwner: true);

        if ($result['state'] === LinkState::LINKED) {
            if (! $wasLinked) {
                $this->logLinked($user, $result['profile'] ?? [], 'firebase', ['promoted' => $wasRole !== $user->fresh()->role]);
            }

            return $result;
        }
        if ($this->isPendingRegistration($user, $result['state'])) {
            return $result;
        }

        $this->refuse($user, $result['state'], $result['message'], 'firebase');
    }

    /** Website-password sign-in (or a session that lost its link): link on the server, verified by Supabase. */
    public function linkServerSide(User $user): array
    {
        if (! $this->platform->isSupabase() || ! $user->canUseWebsite()) {
            return ['state' => LinkState::NOT_APPLICABLE, 'message' => '', 'profile' => null];
        }
        $role = $user->isAdmin() ? 'owner' : 'staff';
        $reasons = [];

        try {
            foreach ($this->candidates($user, $role, $reasons) as $source => $uid) {
                try {
                    $profile = $this->linker->verify($user, $uid);
                } catch (ValidationException $e) {
                    $reasons[] = (string) collect($e->errors())->flatten()->first();

                    continue;
                }

                if ($user->staff_uid !== $profile['firebase_uid']) {
                    if (filled($user->staff_uid)) {
                        $this->linker->unlink($user, $user); // the old link no longer checks out: repair it
                    }
                    $this->linker->link($user, $profile['firebase_uid'], $user);
                    $this->logLinked($user, $profile, $source);
                }
                if (! $user->has_access) {
                    $user->forceFill(['has_access' => true])->save();
                    ActivityLogger::log('access.granted', "Access granted to {$user->email}: verified active app {$profile['role']} account", $user);
                }

                return ['state' => LinkState::LINKED, 'message' => '', 'profile' => $profile];
            }
        } catch (BackendUnavailableException|BackendActionException $e) {
            $this->refuse($user, LinkState::TEMPORARY_ERROR, $e->getMessage(), 'server');
        }

        $message = $reasons
            ? implode(' ', array_unique($reasons))
            : ($role === 'owner'
                ? "No active owner in the app's staff registry (staff_members) has the email {$user->email}. Set ADMIN_STAFF_UID in admin/.env to the owner's Firebase UID, or make the owner's staff_members email match this login."
                : "No staff account in the app's staff registry (staff_members) has the email {$user->email}. An owner must register you in the app's User Management with this email.");
        if ($this->isPendingRegistration($user, LinkState::PROFILE_MISSING) && ! $reasons) {
            return ['state' => LinkState::PROFILE_MISSING, 'message' => $message, 'profile' => null];
        }

        $this->refuse($user, $reasons ? LinkState::ROLE_NOT_AUTHORIZED : LinkState::PROFILE_MISSING, $message, 'server');
    }

    /**
     * source => UID, in the order they are tried. Lazy: the e-mail lookup only runs when the
     * Firebase identity / existing link / ADMIN_STAFF_UID did not already succeed.
     */
    private function candidates(User $user, string $role, array &$reasons): \Generator
    {
        // A login bound to a Firebase account only ever acts as that account.
        if ($user->usesFirebase()) {
            yield 'firebase_uid' => $user->firebase_uid;

            return;
        }
        $tried = [];
        if (filled($user->staff_uid)) {
            yield 'existing_link' => $tried[] = $user->staff_uid;
        }
        $configured = trim((string) config('melai.admin.staff_uid'));
        if ($role === 'owner' && $configured !== '' && ! in_array($configured, $tried, true)) {
            yield 'ADMIN_STAFF_UID' => $tried[] = $configured;
        }

        try {
            $byEmail = $this->gateway->staffUidForEmail(mb_strtolower(trim($user->email)), $role);
        } catch (BackendUnavailableException|BackendActionException $e) {
            if (SupabaseGateway::isMissingFunction($e) || $e instanceof BackendActionException) {
                $reasons[] = 'Finding the app account by email needs the database function portal_staff_uid_for_email: run supabase/migrations/20261013000000_admin_portal_owner_overview.sql'
                    .($role === 'owner' ? ', or set ADMIN_STAFF_UID in admin/.env.' : '.');

                return;
            }
            throw $e;
        }
        if (($byEmail['status'] ?? '') === 'found' && ! in_array($byEmail['firebase_uid'], $tried, true)) {
            yield 'email' => $byEmail['firebase_uid'];
        } elseif (($byEmail['status'] ?? '') === 'ambiguous') {
            $reasons[] = "The app's staff registry has {$byEmail['count']} {$role} accounts with the email {$user->email}, so none was chosen automatically."
                .($role === 'owner' ? ' Set ADMIN_STAFF_UID in admin/.env to the right one.' : ' Ask the owner to fix the duplicates in the app.');
        }
    }

    private function isPendingRegistration(User $user, string $state): bool
    {
        return $state === LinkState::PROFILE_MISSING && ! $user->has_access && ! $user->isAdmin();
    }

    private function logLinked(User $user, array $p, string $source, array $extra = []): void
    {
        ActivityLogger::log('account.auto_linked', "Linked automatically to app {$p['role']} account {$p['full_name']}", $user, [
            'staff_uid' => $p['firebase_uid'] ?? null, 'role' => $p['role'] ?? null, 'branch' => $p['branch_name'] ?? null, 'source' => $source,
        ] + $extra);
    }

    private function refuse(User $user, string $state, string $message, string $method): never
    {
        ActivityLogger::log('auth.autolink_failed', "Sign-in refused for {$user->email}: {$message}", $user, ['state' => $state, 'method' => $method]);
        [$title] = LinkState::describe($state);

        throw new AccountLinkException($state, $state === LinkState::TEMPORARY_ERROR ? $message : "{$title}: {$message}");
    }
}
