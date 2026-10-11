<?php

namespace App\Services\Supabase;

use App\Exceptions\AccountLinkException;
use App\Exceptions\StaffNotLinkedException;
use App\Models\User;
use App\Services\Auth\AccountLinkStatus;
use App\Services\Auth\AutoLinker;
use App\Services\Auth\LinkState;
use App\Services\Firebase\FirebaseSession;
use App\Services\Platform;
use Illuminate\Support\Facades\Auth;

/**
 * Who the admin portal acts as in Supabase: the signed-in Laravel user's linked staff
 * account (users.staff_uid = staff_members.firebase_uid). Owners are linked to an owner
 * row, branch staff to their staff row. Supabase decides what each may see and do: every query
 * goes through SupabaseGateway::actingAs() AS that UID, so RLS and the SQL role checks apply.
 *
 * The UID only ever comes from users.staff_uid in the database, which AutoLinker sets at sign-in
 * after Supabase verified it. Never from a request parameter, a cookie or other input.
 *
 *  - Signed in with Firebase: the session's verified ID token must still belong to that account
 *    (refreshed silently when it expires; a revoked / disabled / forged sign-in ends the session).
 *  - Signed in with the website password: the server-side link is used as it is. The account's
 *    status is still checked with Supabase on every request (current()).
 *  - No link yet (e.g. an owner approved this login after it signed in): linked now, the same way
 *    as at sign-in, with no step for the person.
 */
class StaffIdentity
{
    private array $contexts = [];

    public function __construct(private SupabaseGateway $gateway) {}

    public function uid(?User $user = null): string
    {
        $user ??= Auth::user();
        if (! $user) {
            throw new StaffNotLinkedException('Please sign in.');
        }
        $current = Auth::user()?->is($user) && app(Platform::class)->isSupabase();
        $session = app(FirebaseSession::class);
        $claims = $current && $user->usesFirebase() && $session->has() ? $session->claimsFor($user) : null;

        if (blank($user->staff_uid) && $current) {
            $result = $claims !== null
                ? app(AccountLinkStatus::class)->evaluate($user, $claims, link: true, promoteOwner: true)
                : app(AutoLinker::class)->linkServerSide($user);
            if ($result['state'] !== LinkState::LINKED) {
                throw new AccountLinkException($result['state'], $result['message']);
            }
            $user->refresh();
        }
        if (blank($user->staff_uid)) {
            throw new StaffNotLinkedException('This login is not connected to a Melai Nuts staff or owner account. Please sign in again.');
        }
        if ($claims !== null && $claims['sub'] !== $user->staff_uid) {
            throw new AccountLinkException(LinkState::EMAIL_MISMATCH,
                'You are signed in with a different app account than the one this login belongs to. Please sign in again.');
        }

        return $user->staff_uid;
    }

    /**
     * get_my_staff_context() for a UID: ['status' => 'active'|'not_provisioned'|'inactive'|'suspended'|'invalid_branch',
     * 'profile' => [...], 'authorized_branches' => [['id','name'], ...]]. Cached for the request.
     * $uid is always a verified Firebase UID (token claims or users.staff_uid), never request input.
     */
    public function contextFor(string $uid): array
    {
        return $this->contexts[$uid] ??= $this->gateway->call($uid, 'select public.get_my_staff_context()::text as r') ?? [];
    }

    /**
     * Fallback lookup by e-mail for a verified Firebase identity that has no staff row under its UID:
     * ['found' => bool, 'same_uid' => bool, 'role' => ..., 'account_status' => ...]. Only the caller's
     * own (token) e-mail is looked up; nothing is changed.
     */
    public function registrationByEmail(string $uid, string $email): array
    {
        return $this->gateway->call($uid, 'select public.staff_registration_for_my_email()::text as r', [],
            ['email' => mb_strtolower(trim($email)), 'email_verified' => true]) ?? ['found' => false];
    }

    /** Drop the cached context of $uid (after the staff registry was changed in this request). */
    public function forget(string $uid): void
    {
        unset($this->contexts[$uid]);
    }

    /** Context of the signed-in user. Throws if not linked or no longer active in the app. */
    public function current(): array
    {
        $ctx = $this->contextFor($this->uid());
        if (($ctx['status'] ?? null) !== 'active') {
            $status = $ctx['status'] ?? 'not_provisioned';
            throw new AccountLinkException($status === 'invalid_branch' ? LinkState::BRANCH_MISSING : LinkState::ROLE_NOT_AUTHORIZED,
                $this->statusMessage($status));
        }

        return $ctx;
    }

    public function isOwner(): bool
    {
        return ($this->current()['profile']['role'] ?? null) === 'owner';
    }

    /** [['id' => uuid, 'name' => ...], ...] branches the signed-in user may work with. */
    public function branches(): array
    {
        return $this->current()['authorized_branches'] ?? [];
    }

    public function statusMessage(string $status): string
    {
        return match ($status) {
            'inactive' => 'The linked staff account has been deactivated in the Melai Nuts app.',
            'suspended' => 'The linked staff account is suspended in the Melai Nuts app.',
            'invalid_branch' => 'The linked staff account has no valid branch assigned in the Melai Nuts app.',
            default => 'The linked staff account is not registered in the Melai Nuts app.',
        };
    }
}
