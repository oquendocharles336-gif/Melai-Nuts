<?php

namespace App\Services\Auth;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\StaffLinker;
use Illuminate\Validation\ValidationException;

/**
 * Works out, from the real backends, whether a website login is linked to its Melai Nuts app
 * account, and links it when every check passes:
 *
 *   Firebase  : a verified ID token in this session, for the same email as the login;
 *   Supabase  : get_my_staff_context() asked AS that UID says active, same email, and the role
 *               that fits the login (admin <-> owner, staff <-> staff with a valid branch).
 *
 * Returns ['state' => LinkState::*, 'message' => string, 'profile' => ?array].
 */
class AccountLinkStatus
{
    public function __construct(
        private FirebaseConfig $config,
        private FirebaseSession $session,
        private StaffIdentity $identity,
        private StaffLinker $linker,
    ) {}

    /** State of $user in the current browser session. */
    public function resolve(User $user, bool $link = true, bool $promoteOwner = false): array
    {
        if (! $user->canUseWebsite()) {
            return $this->state(LinkState::NOT_APPLICABLE);
        }
        if (! $this->config->ready()) {
            return $this->state(LinkState::CONFIG_MISSING, $this->config->missingMessage());
        }
        try {
            $claims = $this->session->claimsFor($user);
        } catch (FirebaseSessionRequiredException $e) {
            return $this->state($e->state, $user->usesFirebase() || $e->state !== LinkState::NOT_AUTHENTICATED ? $e->getMessage() : null);
        } catch (BackendUnavailableException $e) {
            return $this->state(LinkState::TEMPORARY_ERROR, $e->getMessage());
        }

        return $this->evaluate($user, $claims, $link, $promoteOwner);
    }

    /**
     * State of $user for the verified Firebase $claims. With $link, an unlinked login whose app
     * account passes every check is linked (and gets website access, since the owner already
     * authorised the account in the app). With $promoteOwner, a "staff" login whose app account
     * (the one just verified by Firebase, and the one it is linked to, if any) is a verified active
     * OWNER becomes an admin login (owner rights come only from the app's staff registry, never
     * from the website). This also covers logins linked while the app account was still staff.
     */
    public function evaluate(User $user, array $claims, bool $link = true, bool $promoteOwner = false): array
    {
        if (! $user->canUseWebsite()) {
            return $this->state(LinkState::NOT_APPLICABLE);
        }
        if ($this->config->requireVerifiedEmail() && ! $claims['email_verified']) {
            return $this->state(LinkState::EMAIL_NOT_VERIFIED);
        }
        $email = $this->norm($user->email);
        if ($this->norm($claims['email']) !== $email) {
            return $this->state(LinkState::EMAIL_MISMATCH, "You are signed in to the app as {$claims['email']}, but this website login is {$user->email}.");
        }
        if (filled($user->staff_uid) && $user->staff_uid !== $claims['sub']) {
            return $this->state(LinkState::EMAIL_MISMATCH, 'This website login is linked to a different app account than the one you signed in with. An admin can unlink it on the Users page.');
        }

        try {
            $ctx = $this->identity->contextFor($claims['sub']);
        } catch (BackendUnavailableException|BackendActionException $e) {
            return $this->state(LinkState::TEMPORARY_ERROR, $e->getMessage());
        }

        $status = $ctx['status'] ?? 'not_provisioned';
        if ($status === 'not_provisioned') {
            return $this->state(LinkState::PROFILE_MISSING, $this->missingProfileMessage($user, $claims));
        }
        if ($status === 'invalid_branch') {
            return $this->state(LinkState::BRANCH_MISSING);
        }
        if ($status !== 'active') {
            return $this->state(LinkState::ROLE_NOT_AUTHORIZED, $this->identity->statusMessage($status));
        }

        $profile = $ctx['profile'];
        if ($this->norm($profile['email'] ?? '') !== $email) {
            return $this->state(LinkState::EMAIL_MISMATCH, "The app's staff registry has this account under {$profile['email']}, not {$user->email}. Ask the owner to correct the email in the app.");
        }

        $expected = $user->isAdmin() ? 'owner' : 'staff';
        if ($profile['role'] !== $expected) {
            // staff_uid is blank or equals $claims['sub'] here (checked above), so this is the same app account.
            if (! ($promoteOwner && $link && $profile['role'] === 'owner' && $user->role === User::ROLE_STAFF)) {
                return $this->state(LinkState::ROLE_NOT_AUTHORIZED, $user->isAdmin()
                    ? 'This is an admin login, but your app account is a staff account. Admin logins need an owner account in the app.'
                    : 'This is a staff login, but your app account is an owner account. Ask an admin to make this login an admin login.');
            }
            $user->forceFill(['role' => User::ROLE_ADMIN])->save();
            $promoted = true;
            if (filled($user->staff_uid)) {
                ActivityLogger::log('account.promoted_from_app_owner', "{$user->email} is now an active owner in the app; login made admin", $user, ['staff_uid' => $claims['sub']]);
            }
        }

        if (blank($user->staff_uid)) {
            if (! $link) {
                return $this->state(LinkState::NOT_AUTHENTICATED, 'Ready to link.');
            }
            try {
                $profile = $this->linker->link($user, $claims['sub'], $user);
                if ($promoted ?? false) {
                    ActivityLogger::log('account.promoted_from_app_owner', "{$user->email} is an active owner in the app; login made admin", $user, ['staff_uid' => $claims['sub']]);
                }
            } catch (ValidationException $e) {
                if ($promoted ?? false) {
                    $user->forceFill(['role' => User::ROLE_STAFF])->save();
                }
                $msg = (string) collect($e->errors())->flatten()->first();

                return $this->state(str_contains($msg, 'already linked') ? LinkState::EMAIL_MISMATCH : LinkState::ROLE_NOT_AUTHORIZED, $msg);
            }
            if (! $user->has_access) {
                $user->forceFill(['has_access' => true])->save();
                ActivityLogger::log('access.granted', "Access granted to {$user->email}: verified active app {$profile['role']} account", $user);
            }
        }

        return $this->state(LinkState::LINKED, null, $profile);
    }

    /**
     * No staff row for the Firebase UID: fall back to the (normalised) e-mail of the verified token
     * to say precisely what is wrong. Nothing is linked by e-mail alone: the staff registry is keyed
     * by Firebase UID, and re-pointing a row to another UID is the owner's decision in the app.
     */
    public function missingProfileMessage(User $user, array $claims): string
    {
        return $this->registeredUnderAnotherUid($claims) ?? ($user->has_access
            ? "Your Melai Nuts app account ({$claims['email']}) is not registered in the app's staff registry (staff_members) as staff or owner. "
                .'An owner must register it in the app\'s User Management, or approve this login on the website\'s Users page.'
            : 'Your app account exists in Firebase, but no owner has approved it yet. An owner approves it on the website\'s Users page (or registers you in the app\'s User Management).');
    }

    /** The precise message when the token's e-mail IS in the staff registry, but under another Firebase UID. */
    public function registeredUnderAnotherUid(array $claims): ?string
    {
        try {
            $byEmail = $this->identity->registrationByEmail($claims['sub'], (string) $claims['email']);
        } catch (BackendUnavailableException|BackendActionException) {
            return null;
        }
        if (! ($byEmail['found'] ?? false) || ($byEmail['same_uid'] ?? false)) {
            return null;
        }
        $role = ($byEmail['role'] ?? '') === 'owner' ? 'an owner' : 'a staff member';

        return "The app's staff registry lists {$claims['email']} as {$role}, but under a different Firebase account than the one you signed in with. "
            .'Nothing was linked. The owner must register this Firebase account in the app\'s User Management (or remove the old entry and add it again).';
    }

    private function state(string $state, ?string $message = null, ?array $profile = null): array
    {
        [, , $default] = LinkState::describe($state);

        return ['state' => $state, 'message' => $message ?? $default, 'profile' => $profile];
    }

    private function norm(?string $email): string
    {
        return mb_strtolower(trim((string) $email));
    }
}
