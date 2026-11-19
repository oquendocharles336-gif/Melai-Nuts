<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\User;
use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Services\ActivityLogger;
use App\Services\Auth\AccountProvisioner;
use App\Services\Platform;
use App\Services\Supabase\StaffLinker;
use App\Services\Supabase\SupabaseRepository;
use App\Services\UserDirectory;
use Illuminate\Http\Request;

/**
 * Admin-only user management: the all-users view (website logins + every app account),
 * link/unlink, grant/restrict access, activate/deactivate. Staff and owner accounts are created
 * ONLY in the Melai Nuts app (User Management); the website never creates or approves one.
 */
class UserController extends Controller
{
    /**
     * All users: website logins merged with every account in the app (owners, staff,
     * customers; riders are app-only and not listed), filterable by type and searchable. The link / access controls of
     * the website logins are unchanged.
     */
    public function index(Request $request, Platform $platform, UserDirectory $people)
    {
        $type = array_key_exists($request->query('type'), UserDirectory::TYPES) ? $request->query('type') : 'all';
        $q = mb_substr(trim((string) $request->query('q', '')), 0, 100);

        $app = null;
        $branches = [];
        $directoryError = null;
        // Every app account and the owner's branches (owner-only in Supabase).
        if ($platform->isSupabase() && auth()->user()->staff_uid) {
            try {
                // SPEED: cached per account like the dashboard (fresh only); any change on this website
                // (approve, link, access, ...) invalidates it at once; ?fresh=1 reloads.
                $limit = (int) config('melai.users_customer_limit', 500);
                $app = \App\Support\Swr::remember("all-users:$limit:".sha1($q), \App\Support\Swr::fresh(), \App\Support\Swr::fresh(),
                    fn () => app(SupabaseRepository::class)->allUsers($q, $limit));
                $branches = $platform->branches();
            } catch (BackendActionException|BackendUnavailableException|\App\Exceptions\AccountLinkException $e) {
                $directoryError = $e->getMessage();
            }
        } elseif ($platform->isSupabase()) {
            $directoryError = 'Your login is not linked to an owner account in the app yet, so only website logins are listed.';
        }

        $everyone = $people->people(User::orderBy('name')->get(), $app, $request->user());
        $searched = $people->filter($everyone, 'all', $q);
        $list = $people->filter($searched, $type, null);
        $paginator = \App\Support\ListTools::paginate($list->values()->all(), $request);

        return view('admin.users.index', [
            'people' => $paginator,
            'type' => $type,
            'q' => $q,
            'counts' => $people->counts($searched),
            'totals' => $people->counts($everyone),
            'liveData' => $platform->isSupabase(),
            'needsOwnerPassword' => $platform->isSupabase() && app(AccountProvisioner::class)->needsOwnerPassword($request->user()),
            'appLoaded' => $app !== null,
            'partial' => (bool) ($app['partial'] ?? false),
            'customersShown' => count($app['customers'] ?? []),
            'customersTotal' => (int) ($app['customers_total'] ?? 0),
            'directory' => collect($app['staff'] ?? [])->keyBy('firebase_uid')->all(),
            // Logins an admin created on this website (Create account): their row shows only the app account,
            // without the website-login badge and the Restrict / Grant access button.
            'createdHere' => \App\Models\ActivityLog::where('action', 'account.created_by_admin')->whereNotNull('user_id')
                ->pluck('user_id')->flip()->all(),
            'branches' => $branches,
            'directoryError' => $directoryError,
        ]);
    }

    /** Link a portal login to its staff/owner account in the app (verified by Supabase, see StaffLinker). */
    public function link(Request $request, User $user, StaffLinker $linker, Platform $platform)
    {
        abort_unless($platform->isSupabase(), 404);
        $data = $request->validate(['staff_uid' => ['required', 'string', 'max:128']]);
        $profile = $linker->link($user, $data['staff_uid'], $request->user());

        return back()->with('status', "{$user->email} is now linked to the app {$profile['role']} account \"{$profile['full_name']}\".");
    }

    /** Disable / enable a staff member's or customer's app account (see AppAccountStatus). */
    public function setAppActive(Request $request, string $uid, AccountProvisioner $provisioner, \App\Services\Auth\AppAccountStatus $status, Platform $platform)
    {
        abort_unless($platform->isSupabase(), 404);
        abort_unless(preg_match('/^[A-Za-z0-9:_-]{1,128}$/', $uid) === 1, 404);
        $data = $request->validate(['active' => ['required', 'boolean'], 'name' => ['nullable', 'string', 'max:120']]);
        $active = (bool) $data['active'];
        $token = $provisioner->ownerToken($request->user(), $request->input('owner_password'));
        $kind = $status->set($uid, $active, $request->user(), $token);
        $who = $data['name'] ?? 'The account';

        return back()->with('status', $active
            ? "{$who} is enabled again and can sign in."
            : "{$who} is disabled: this {$kind} can no longer sign in to the Melai Nuts app".($kind === 'staff' ? ' or this website' : '').'.');
    }

    public function unlink(Request $request, User $user, StaffLinker $linker, Platform $platform)
    {
        abort_unless($platform->isSupabase(), 404);
        abort_if($user->is($request->user()), 403, 'You cannot unlink your own account.');
        $linker->unlink($user, $request->user());

        return back()->with('status', "{$user->email} is no longer linked to an app account.");
    }

    /** Give or restrict dashboard access (has_access). Admins can't be restricted this way. */
    public function toggleAccess(Request $request, User $user)
    {
        abort_if($user->isAdmin(), 403);

        $user->forceFill(['has_access' => ! $user->has_access])->save();
        ActivityLogger::log($user->has_access ? 'access.granted' : 'access.restricted', "{$request->user()->name} changed access for {$user->email}", $user);

        return back()->with('status', $user->has_access ? "Access granted to {$user->email}." : "Access restricted for {$user->email}.");
    }

    /** Deactivate/reactivate a login. Admins can't deactivate themselves or other admins here. */
    public function toggleActive(Request $request, User $user)
    {
        abort_if($user->isAdmin(), 403);

        $user->forceFill(['is_active' => ! $user->is_active])->save();
        ActivityLogger::log($user->is_active ? 'account.activated' : 'account.deactivated', "{$request->user()->name} toggled status for {$user->email}", $user);

        return back()->with('status', $user->is_active ? "{$user->email} reactivated." : "{$user->email} deactivated.");
    }
}
