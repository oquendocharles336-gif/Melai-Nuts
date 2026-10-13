<?php

namespace App\Services\Auth;

use App\Exceptions\BackendActionException;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirestoreProfiles;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Support\Facades\Log;
use Illuminate\Validation\ValidationException;

/**
 * Owner disables / enables a staff member's or customer's Melai Nuts account from the website,
 * the same way the app's User Management does it (AuthService.setAccountActive):
 *
 *   1. the database: staff -> owner_set_staff_active, customer -> owner_set_customer_active
 *      (both owner-only SQL functions, run AS the signed-in owner);
 *   2. Firestore users/{uid}.isActive, written with the owner's ID token: the app's sign-in
 *      check and firestore.rules read it, so a disabled person can no longer sign in to the app;
 *   3. a website login of that account follows (users.is_active), so it is cut off here too.
 *
 * If step 2 fails, step 1 is undone: nothing is left half-changed. Owner accounts are not
 * changed here (they are managed in the app), and nobody can disable their own account.
 */
class AppAccountStatus
{
    public function __construct(
        private SupabaseRepository $repo,
        private StaffIdentity $identity,
        private FirestoreProfiles $firestore,
    ) {}

    /** @return string 'staff' or 'customer' */
    public function set(string $uid, bool $active, User $owner, string $ownerToken): string
    {
        if ($uid === $this->identity->uid($owner)) {
            throw ValidationException::withMessages(['account' => 'You cannot disable your own account.']);
        }

        $staff = collect($this->repo->staffDirectory())->firstWhere('firebase_uid', $uid);
        if (($staff['role'] ?? null) === 'owner') {
            throw ValidationException::withMessages(['account' => 'Owner accounts are managed in the Melai Nuts app.']);
        }
        $kind = $staff ? 'staff' : 'customer';
        $name = $staff['full_name'] ?? null;

        try {
            $kind === 'staff' ? $this->repo->setStaffActive($uid, $active) : $this->repo->setCustomerActive($uid, $active);
        } catch (BackendActionException $e) {
            throw ValidationException::withMessages(['account' => $e->getMessage()]);
        }

        try {
            $this->firestore->setActive($ownerToken, $uid, $active);
        } catch (FirebaseAuthException $e) {
            try {   // undo step 1
                $kind === 'staff' ? $this->repo->setStaffActive($uid, ! $active) : $this->repo->setCustomerActive($uid, ! $active);
            } catch (\Throwable $rollback) {
                Log::error('[account-status] could not undo the database change', ['uid' => $uid, 'error' => $rollback->getMessage()]);
            }
            throw ValidationException::withMessages(['account' => $e->getMessage().' Nothing was changed.']);
        }

        // Website logins of this account (never an admin login) follow.
        User::where(fn ($q) => $q->where('staff_uid', $uid)->orWhere('firebase_uid', $uid))
            ->where('role', '!=', User::ROLE_ADMIN)->get()
            ->each(fn (User $u) => $u->forceFill(['is_active' => $active])->save());
        $this->identity->forget($uid);

        ActivityLogger::log($active ? 'account.app_enabled' : 'account.app_disabled',
            ($active ? 'Enabled' : 'Disabled')." the app {$kind} account {$uid}".($name ? " ({$name})" : ''), $owner, ['firebase_uid' => $uid, 'kind' => $kind]);

        return $kind;
    }
}
