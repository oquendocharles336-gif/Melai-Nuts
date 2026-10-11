<?php

namespace App\Services;

use App\Models\User;
use Carbon\Carbon;
use Illuminate\Support\Collection;

/**
 * Builds the all-users view: every person who has an account anywhere in Melai Nuts, one row
 * per person.
 *
 *   - website logins (this site's users table: admin / staff)
 *   - app owners and staff (staff_members)
 *   - app customers (customer_profiles)
 *
 * Riders are app-only accounts managed in the app's User Management; they are not listed here.
 *
 * Records are merged into one person ONLY when they share a Firebase UID (a login's staff_uid
 * or firebase_uid). Two records with the same e-mail but different UIDs stay separate rows:
 * the same e-mail is not proof that it is the same account (linking stays an explicit admin
 * action, see StaffLinker).
 */
class UserDirectory
{
    public const TYPES = [
        'all' => 'All',
        'attention' => 'Needs attention',
        'logins' => 'Website logins',
        'team' => 'Owners & staff',
        'customers' => 'Customers',
    ];

    /**
     * @param  Collection<int, User>  $logins
     * @param  array|null  $app  SupabaseRepository::allUsers() answer, or null when the app's
     *                           accounts could not be loaded (then only logins are listed).
     * @return Collection<int, array>
     */
    public function people(Collection $logins, ?array $app, ?User $viewer = null): Collection
    {
        $people = [];
        $byUid = [];
        $staffRows = collect($app['staff'] ?? [])->keyBy('firebase_uid');

        foreach ($logins as $u) {
            $key = 'login:'.$u->id;
            $people[$key] = ['login' => $u] + $this->blank($key);
            foreach (array_filter([$u->staff_uid, $u->firebase_uid]) as $uid) {
                $byUid[$uid] ??= $key;
            }
        }

        $attach = function (string $slot, array $row) use (&$people, &$byUid) {
            $uid = (string) ($row['firebase_uid'] ?? '');
            $key = $byUid[$uid] ?? 'app:'.$uid;
            $people[$key] ??= $this->blank($key);
            $people[$key][$slot] = $row;
            $byUid[$uid] = $key;
        };
        foreach ($app['staff'] ?? [] as $row) {
            $attach('staff', $row);
        }
        foreach ($app['customers'] ?? [] as $row) {
            $attach('customer', $row);
        }

        return collect($people)
            ->map(fn ($p) => $this->describe($p, $app !== null, $staffRows, $viewer))
            ->sortBy([['attention', 'desc'], ['rank', 'asc'], [fn ($a, $b) => strnatcasecmp($a['name'], $b['name'])]])
            ->values();
    }

    /** People of one type (a TYPES key) matching a free-text search. */
    public function filter(Collection $people, string $type, ?string $search): Collection
    {
        $q = mb_strtolower(trim((string) $search));

        return $people
            ->filter(fn ($p) => $type === 'all' || ($type === 'attention' ? $p['attention'] : in_array($type, $p['types'], true)))
            ->filter(fn ($p) => $q === '' || str_contains($p['haystack'], $q))
            ->values();
    }

    /** [type => number of people] for the filter chips. */
    public function counts(Collection $people): array
    {
        return collect(array_keys(self::TYPES))->mapWithKeys(fn ($t) => [$t => $this->filter($people, $t, null)->count()])->all();
    }

    private function blank(string $key): array
    {
        return ['key' => $key, 'login' => null, 'staff' => null, 'customer' => null];
    }

    private function describe(array $p, bool $appLoaded, Collection $staffRows, ?User $viewer): array
    {
        /** @var User|null $login */
        $login = $p['login'];
        $staff = $p['staff'];
        $customer = $p['customer'];

        $name = $login?->name ?: ($staff['full_name'] ?? null) ?: ($customer['full_name'] ?? 'Unnamed');
        $email = $login?->email ?: ($staff['email'] ?? null) ?: ($customer['email'] ?? null);
        $phone = $customer['phone'] ?? null;
        $branch = ($staff['branch_name'] ?? null)
            ?: (($staff['role'] ?? null) === 'owner' ? 'All branches' : null) ?: ($customer['branch_name'] ?? null);

        $types = array_values(array_filter([
            $login ? 'logins' : null,
            $staff ? 'team' : null,
            $customer ? 'customers' : null,
        ]));

        // A website registration (Firebase account, no app staff row yet) waiting for Approve.
        // Same rule the page has always used; only decidable when the app's staff list loaded.
        $awaitingApproval = $login && $appLoaded && $login->firebase_uid && ! $login->staff_uid
            && $login->canUseWebsite() && ! $staffRows->has($login->firebase_uid)
            && ! ($viewer && $login->is($viewer));

        $status = match (true) {
            $login && ! $login->is_active => ['bad', 'Deactivated'],
            $staff && ($staff['account_status'] ?? 'active') !== 'active' => ['bad', 'App '.($staff['account_status'] ?? 'inactive')],
            $staff && array_key_exists('is_active', $staff) && ! $staff['is_active'] => ['bad', 'App inactive'],
            $login && ! $login->canUseWebsite() => ['bad', 'No website access'],
            $awaitingApproval => ['warn', 'Needs approval'],
            $login && ! $login->has_access => ['warn', 'Waiting for access'],
            default => ['ok', 'Active'],
        };

        $lastSeen = collect([$login?->last_login_at, $this->date($customer['last_order_at'] ?? null)])->filter()->max();
        $joined = collect([$login?->created_at, $this->date($staff['created_at'] ?? null),
            $this->date($customer['created_at'] ?? null)])->filter()->min();

        $rank = match (true) {
            $login?->isAdmin() || ($staff['role'] ?? null) === 'owner' => 0,
            $login !== null || $staff !== null => 1,
            default => 2,
        };

        return $p + [
            'name' => $name,
            'email' => $email,
            'phone' => $phone,
            'branch' => $branch,
            'types' => $types,
            'status' => $status,
            'attention' => $status[0] === 'warn',
            'awaiting_approval' => $awaitingApproval,
            'last_seen' => $lastSeen,
            'joined' => $joined,
            'rank' => $rank,
            'initials' => $this->initials($name),
            'haystack' => mb_strtolower(implode(' ', array_filter([$name, $email, $phone, $branch, $customer['card_number'] ?? null,
                $login?->role, $staff['role'] ?? null, $customer ? 'customer' : null]))),
        ];
    }

    private function date(?string $iso): ?Carbon
    {
        return $iso ? Carbon::parse($iso)->setTimezone(config('app.timezone')) : null;
    }

    private function initials(string $name): string
    {
        $parts = collect(preg_split('/\s+/', trim($name)))->filter()->values();

        return mb_strtoupper(mb_substr($parts->first() ?? '?', 0, 1).($parts->count() > 1 ? mb_substr($parts->last(), 0, 1) : ''));
    }
}
