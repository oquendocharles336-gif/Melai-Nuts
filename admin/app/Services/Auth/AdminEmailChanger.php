<?php

namespace App\Services\Auth;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\StaffLinker;
use App\Services\Supabase\SupabaseGateway;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * Changes the email of an EXISTING admin login in place (same users.id), used by
 * `php artisan melai:change-admin-email` and by AdminSeeder when ADMIN_EMAIL changes.
 *
 * Kept: id, name, password, role, is_active, has_access, activity logs.
 * Changed: email (lower-cased), email_verified_at (now() only when Supabase confirms an active
 * owner account with the new email, else null), remember_token (rotated).
 * staff_uid / firebase_uid are cleared only when they point to an app account whose email is not
 * the new email; then the login is re-linked to the active owner with the new email (verified by
 * Supabase get_my_staff_context, same rules as melai:link-staff). Existing sessions are deleted.
 */
class AdminEmailChanger
{
    public function __construct(
        private StaffIdentity $identity,
        private StaffLinker $linker,
        private SupabaseGateway $gateway,
    ) {}

    /** The admin login to change: the user with $oldEmail, else the single admin named like ADMIN_NAME ("Melai Admin"). */
    public function findAdmin(?string $oldEmail): ?User
    {
        if (filled($oldEmail) && ($u = User::where('email', $this->norm($oldEmail))->first())) {
            return $u;
        }
        $byName = User::where('role', User::ROLE_ADMIN)->where('name', config('melai.admin.name') ?: 'Melai Admin')->get();
        if ($byName->count() > 1) {
            throw ValidationException::withMessages(['old' => 'More than one admin is named "'.$byName->first()->name.'" ('
                .$byName->pluck('email')->implode(', ').'). Give the exact old email.']);
        }

        return $byName->first();
    }

    /**
     * @param  ?string  $ownerUid  Firebase UID of the owner account to link (optional; found automatically otherwise)
     * @param  bool  $skipLink  change the email even when Supabase cannot be reached (unverifiable links are cleared)
     * @return array{old: string, new: string, user: User, linked: ?array, link_error: ?string, cleared: string[], sessions: int|null}
     */
    public function change(User $admin, string $newEmail, ?string $ownerUid = null, bool $skipLink = false): array
    {
        $new = $this->norm($newEmail);
        Validator::make(['email' => $new], ['email' => ['required', 'email:rfc', 'max:255']])->validate();
        if ($admin->role !== User::ROLE_ADMIN) {
            throw ValidationException::withMessages(['old' => "{$admin->email} is not an admin login."]);
        }
        if (User::where('email', $new)->where('id', '!=', $admin->id)->exists()) {
            throw ValidationException::withMessages(['email' => "Another login already uses {$new}. Nothing was changed."]);
        }

        // 1. Ask Supabase which app account is the active owner with the new email (before changing anything).
        $target = null;          // verified owner profile for $new
        $owners = [];            // uid => profile email, for every candidate UID Supabase answered for
        $linkError = null;
        $supabase = app(\App\Services\Platform::class)->isSupabase();
        $hasCandidate = collect([$ownerUid, config('melai.admin.staff_uid'), $admin->staff_uid, $admin->firebase_uid])->filter(fn ($u) => filled($u))->isNotEmpty();
        if ($supabase && ! $hasCandidate) {
            $linkError = 'The owner account could not be looked up automatically: this login has no staff_uid / firebase_uid and ADMIN_STAFF_UID is empty. '
                .'Pass --uid=<owner Firebase UID> (or run melai:link-staff), or sign in to the website once with the owner\'s app email and password.';
        } elseif ($supabase) {
            try {
                [$target, $owners] = $this->findOwner($admin, $new, $ownerUid);
            } catch (BackendUnavailableException|BackendActionException $e) {
                if (! $skipLink) {
                    throw ValidationException::withMessages(['supabase' => 'Supabase could not be reached, so the owner link cannot be checked: '
                        .$e->getMessage().' Nothing was changed. Retry, or add --skip-link to change the email now and link later with melai:link-staff.']);
                }
                $linkError = $e->getMessage();
            }
            if (! $target && ! $linkError) {
                $linkError = "No active owner account with the email {$new} was found in the app's staff registry (Supabase staff_members).";
            }
        }

        // 2. Update the same row.
        $old = $admin->email;
        $cleared = [];
        $sessions = null;
        DB::transaction(function () use ($admin, $new, $target, $owners, &$cleared, &$sessions) {
            $keep = fn (?string $uid) => blank($uid)
                || ($target && $uid === $target['firebase_uid'])
                || (isset($owners[$uid]) && $owners[$uid] === $new);

            $fill = [
                'email' => $new,
                'email_verified_at' => $target ? now() : null,
                'remember_token' => Str::random(60), // kills every "remember me" cookie
            ];
            if (! $keep($admin->staff_uid)) {
                $cleared[] = "staff_uid ({$admin->staff_uid})";
                $fill += ['staff_uid' => null, 'staff_linked_at' => null];
            }
            if (! $keep($admin->firebase_uid)) {
                // The login was bound to the Firebase account of the old email. Unbinding lets the
                // new email's Firebase account bind at its first website sign-in.
                $cleared[] = "firebase_uid ({$admin->firebase_uid})";
                $fill += ['firebase_uid' => null, 'firebase_email_verified' => false];
            }
            $admin->forceFill($fill)->save();

            if (config('session.driver') === 'database') {
                $sessions = DB::connection(config('session.connection'))->table(config('session.table', 'sessions'))
                    ->where('user_id', $admin->id)->delete();
            }
        });

        ActivityLogger::log('account.admin_email_changed', 'Admin email changed', $admin, [
            'user_id' => $admin->id, 'old_email' => $old, 'new_email' => $new, 'cleared' => $cleared,
        ]);

        // 3. Automatic owner link (StaffLinker re-checks status, email and role in Supabase).
        $linked = null;
        if ($target) {
            if ($admin->staff_uid === $target['firebase_uid']) {
                $linked = $target;
            } else {
                try {
                    $this->identity->forget($target['firebase_uid']);
                    $linked = $this->linker->link($admin, $target['firebase_uid']);
                } catch (ValidationException $e) {
                    $linkError = (string) collect($e->errors())->flatten()->first();
                } catch (BackendUnavailableException|BackendActionException $e) {
                    $linkError = $e->getMessage();
                }
            }
        }

        return ['old' => $old, 'new' => $new, 'user' => $admin->fresh(), 'linked' => $linked,
            'link_error' => $linked ? null : $linkError, 'cleared' => $cleared, 'sessions' => $sessions];
    }

    /**
     * Candidate UIDs: --uid, ADMIN_STAFF_UID, the login's current staff_uid / firebase_uid. Each is
     * checked with get_my_staff_context(). If none is the owner with $new, the owner directory is read
     * AS an active owner among them to find the owner row with $new.
     * @return array{0: ?array, 1: array<string,string>}
     */
    private function findOwner(User $admin, string $new, ?string $ownerUid): array
    {
        $candidates = collect([$ownerUid, config('melai.admin.staff_uid'), $admin->staff_uid, $admin->firebase_uid])
            ->map(fn ($u) => trim((string) $u))->filter()->unique()->values();

        $owners = [];
        $activeOwnerUid = null;
        foreach ($candidates as $uid) {
            $ctx = $this->identity->contextFor($uid);
            $p = $ctx['profile'] ?? null;
            if (! $p) {
                continue;
            }
            $owners[$uid] = $this->norm($p['email'] ?? '');
            $isActiveOwner = ($ctx['status'] ?? null) === 'active' && ($p['role'] ?? null) === 'owner';
            if ($isActiveOwner && $owners[$uid] === $new) {
                return [$p, $owners];
            }
            $activeOwnerUid ??= $isActiveOwner ? $uid : null;
        }

        if ($activeOwnerUid) {
            $row = collect($this->gateway->call($activeOwnerUid, 'select public.admin_portal_staff_directory()::text as r') ?? [])
                ->first(fn ($s) => $this->norm($s['email'] ?? '') === $new && ($s['role'] ?? null) === 'owner');
            if ($row) {
                $ctx = $this->identity->contextFor($row['firebase_uid']);
                if (($ctx['status'] ?? null) === 'active' && $this->norm($ctx['profile']['email'] ?? '') === $new
                    && ($ctx['profile']['role'] ?? null) === 'owner') {
                    return [$ctx['profile'], $owners];
                }
            }
        }

        return [null, $owners];
    }

    private function norm(?string $email): string
    {
        return mb_strtolower(trim((string) $email));
    }
}
