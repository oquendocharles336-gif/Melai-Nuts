<?php

namespace App\Services\Supabase;

use App\Models\User;
use App\Services\ActivityLogger;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Validation\ValidationException;

/**
 * Links an admin-portal login to a registered Melai Nuts staff/owner account.
 *
 * A link is accepted only when Supabase itself confirms (get_my_staff_context, asked AS that
 * account) that the account is active, its email matches the portal login's email, and its
 * role fits the portal role: portal admins must be app owners, portal staff must be app staff.
 * Logins whose role may not use the website are never linked.
 */
class StaffLinker
{
    public function __construct(private StaffIdentity $identity) {}

    /** @return array the verified staff profile */
    public function verify(User $user, string $uid): array
    {
        $uid = trim($uid);
        if ($uid === '' || ! preg_match('/^[A-Za-z0-9:_-]{1,128}$/', $uid)) {
            throw ValidationException::withMessages(['staff_uid' => 'That is not a valid Firebase UID.']);
        }
        if (! $user->canUseWebsite()) {
            throw ValidationException::withMessages(['staff_uid' => 'This login cannot use the website, so it cannot be linked.']);
        }
        if (User::where('staff_uid', $uid)->where('id', '!=', $user->id)->exists()) {
            throw ValidationException::withMessages(['staff_uid' => 'That staff account is already linked to another admin-portal login.']);
        }

        $ctx = $this->identity->contextFor($uid);
        if (($ctx['status'] ?? null) !== 'active') {
            throw ValidationException::withMessages(['staff_uid' => $this->identity->statusMessage($ctx['status'] ?? 'not_provisioned')]);
        }
        $profile = $ctx['profile'];

        if (mb_strtolower(trim($profile['email'] ?? '')) !== mb_strtolower(trim($user->email))) {
            throw ValidationException::withMessages(['staff_uid' => "The app account's email ({$profile['email']}) does not match this login's email ({$user->email})."]);
        }
        $expected = $user->isAdmin() ? 'owner' : 'staff';
        if ($profile['role'] !== $expected) {
            throw ValidationException::withMessages(['staff_uid' => $user->isAdmin()
                ? 'Admin logins must be linked to an owner account in the app.'
                : 'Staff logins must be linked to a staff account in the app.']);
        }

        return $profile;
    }

    public function link(User $user, string $uid, ?User $by = null): array
    {
        $profile = $this->verify($user, $uid);
        try {
            // users.staff_uid is unique: two logins can never share one app account, even if two links race.
            $user->forceFill(['staff_uid' => $profile['firebase_uid'], 'staff_linked_at' => now()])->save();
        } catch (UniqueConstraintViolationException) {
            throw ValidationException::withMessages(['staff_uid' => 'That staff account is already linked to another admin-portal login.']);
        }
        ActivityLogger::log('account.staff_linked', "Linked {$user->email} to app {$profile['role']} account {$profile['full_name']}", $by, [
            'user_id' => $user->id, 'staff_uid' => $profile['firebase_uid'], 'role' => $profile['role'], 'branch' => $profile['branch_name'] ?? null,
        ]);

        return $profile;
    }

    public function unlink(User $user, ?User $by = null): void
    {
        $old = $user->staff_uid;
        $user->forceFill(['staff_uid' => null, 'staff_linked_at' => null])->save();
        ActivityLogger::log('account.staff_unlinked', "Unlinked {$user->email} from its app account", $by, ['user_id' => $user->id, 'staff_uid' => $old]);
    }
}
