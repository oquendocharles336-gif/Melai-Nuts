<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Http\Requests\AdminCreateUserRequest;
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
use Illuminate\Validation\ValidationException;

/**
 * Admin-only user management: the all-users view (website logins + every app account),
 * create staff accounts, approve website registrations
 * (registers them as app staff/owner, AccountProvisioner), link/unlink, grant/restrict access,
 * activate/deactivate.
 */
class UserController extends Controller
{
    /**
     * All users: website logins merged with every account in the app (owners, staff,
     * customers; riders are app-only and not listed), filterable by type and searchable. The link / approve / access controls of
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
                $app = app(SupabaseRepository::class)->allUsers($q, (int) config('melai.users_customer_limit', 500));
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
        $perPage = 50;
        $page = max(1, (int) $request->query('page', 1));
        $paginator = new \Illuminate\Pagination\LengthAwarePaginator(
            $list->forPage($page, $perPage)->values(), $list->count(), $perPage, $page,
            ['path' => $request->url(), 'query' => $request->query()]);

        return view('admin.users.index', [
            'people' => $paginator,
            'type' => $type,
            'q' => $q,
            'counts' => $people->counts($searched),
            'totals' => $people->counts($everyone),
            'liveData' => $platform->isSupabase(),
            'appLoaded' => $app !== null,
            'partial' => (bool) ($app['partial'] ?? false),
            'customersShown' => count($app['customers'] ?? []),
            'customersTotal' => (int) ($app['customers_total'] ?? 0),
            'directory' => collect($app['staff'] ?? [])->keyBy('firebase_uid')->all(),
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

    /** Approve a website registration: register its Firebase account as app staff/owner and link it. */
    public function approve(Request $request, User $user, AccountProvisioner $provisioner, Platform $platform)
    {
        abort_unless($platform->isSupabase(), 404);
        $data = $request->validate([
            'role' => ['required', 'in:staff,owner'],
            'branch_id' => ['nullable', 'required_if:role,staff', 'uuid'],
        ]);
        $profile = $provisioner->approve($user, $data['role'], $data['branch_id'] ?? null, $request->user());

        return back()->with('status', "{$user->email} is now registered in the app as {$profile['role']}"
            .(($profile['branch_name'] ?? null) ? " ({$profile['branch_name']})" : '').' and can use the website.');
    }

    public function unlink(Request $request, User $user, StaffLinker $linker, Platform $platform)
    {
        abort_unless($platform->isSupabase(), 404);
        abort_if($user->is($request->user()), 403, 'You cannot unlink your own account.');
        $linker->unlink($user, $request->user());

        return back()->with('status', "{$user->email} is no longer linked to an app account.");
    }

    public function create(Platform $platform)
    {
        $branches = [];
        if ($platform->isSupabase() && auth()->user()->staff_uid) {
            try {
                $branches = $platform->branches();
            } catch (\Throwable) {
                $branches = [];
            }
        }

        return view('admin.users.create', ['liveData' => $platform->isSupabase(), 'branches' => $branches]);
    }

    public function store(AdminCreateUserRequest $request, Platform $platform, AccountProvisioner $provisioner)
    {
        $data = $request->validated();

        // Staff on the real website are Melai Nuts app accounts: Firebase account + app staff
        // registration + linked login, created together exactly like the app's User Management.
        if ($platform->isSupabase() && $data['role'] === User::ROLE_STAFF) {
            $request->validate(['branch_id' => ['required', 'uuid']]);
            [$user, $profile] = $provisioner->createStaff($data['name'], $data['email'], $data['password'], $request->input('branch_id'), $request->user());
            ActivityLogger::log('account.created_by_admin', "Admin created app staff account: {$user->email}", $user, [
                'role' => $user->role, 'created_by' => $request->user()->id, 'branch' => $profile['branch_name'] ?? null,
            ]);

            return redirect()->route('admin.users.index')->with('status', "App staff account created for {$user->email} ({$profile['branch_name']}). They sign in to the app and this website with that email and password.");
        }

        try {
            $user = (new User)->forceFill([
                'name' => $data['name'],
                'email' => $data['email'],
                'password' => $data['password'],
                'role' => $data['role'],
                'is_active' => true,
                'has_access' => true, // admin created this account on purpose, so it's usable right away
            ]);
            $user->save();
        } catch (\Illuminate\Database\UniqueConstraintViolationException) {
            throw ValidationException::withMessages(['email' => 'An account with this email already exists.']);
        }

        ActivityLogger::log('account.created_by_admin', "Admin created account: {$user->email}", $user, [
            'role' => $user->role, 'created_by' => $request->user()->id,
        ]);

        return redirect()->route('admin.users.index')->with('status', "Account created for {$user->email}.");
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
