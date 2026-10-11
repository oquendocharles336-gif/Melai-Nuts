<?php

namespace App\Services;

use App\Services\Supabase\StaffIdentity;

/**
 * Branch list and payment-method vocabulary of the Melai Nuts app, for the website.
 * Everything comes from the app's database; the only local settings are the optional sales
 * targets in config/melai.php. (The automated tests swap this class for
 * tests/Support/MockPlatform.)
 */
class Platform
{
    public function __construct(private StaffIdentity $identity) {}

    public function isSupabase(): bool
    {
        return true; // the website has no other data source (only the test suite's MockPlatform says false)
    }

    /**
     * Branches the signed-in user can see (owner: all, staff: their own), each as
     * ['id', 'name', 'daily_target']; daily_target is null unless the owner configured one.
     * (No map positions: the website has no maps.)
     */
    public function branches(): array
    {
        $targets = collect(config('melai.targets', []))->mapWithKeys(fn ($v, $k) => [mb_strtolower($k) => (float) $v]);
        $authorized = $this->identity->branches(); // first: checks the sign-in and the account status

        return collect($authorized)->map(fn ($b) => [
            'id' => $b['id'],
            'name' => $b['name'],
            'daily_target' => $targets->get(mb_strtolower($b['name']), config('melai.default_daily_target')),
        ])->values()->all();
    }

    /** Payment method keys as the app stores them. */
    public function paymentMethods(): array
    {
        return ['gcash', 'maya', 'card', 'cash'];
    }

    /** The method an admin may mark paid by hand (cash collected at the counter / on delivery). */
    public function cashMethod(): string
    {
        return 'cash';
    }

    public function branchName(?string $id): string
    {
        return collect($this->branches())->firstWhere('id', $id)['name'] ?? '—';
    }
}
