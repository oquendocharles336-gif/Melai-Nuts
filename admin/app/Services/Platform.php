<?php

namespace App\Services;

use App\Services\Supabase\StaffIdentity;

/**
 * Branch list and payment-method vocabulary of the Melai Nuts app, for the website.
 * Everything comes from the app's database, including the owner's daily sales targets
 * (branches.daily_sales_target, else business_settings.default_daily_sales_target; none = no
 * target). (The automated tests swap this class for a stand-in under tests/Support.)
 */
class Platform
{
    public function __construct(private StaffIdentity $identity) {}

    public function isSupabase(): bool
    {
        return true; // the website has no other data source (only the test suite's stand-in says false)
    }

    /**
     * Branches the signed-in user can see (owner: all, staff: their own), each as
     * ['id', 'name', 'daily_target']; daily_target is null unless the owner set one in the database.
     * (No map positions: the website has no maps.)
     */
    public function branches(): array
    {
        $authorized = $this->identity->branches(); // first: checks the sign-in and the account status
        $settings = $this->settings();
        $byId = collect($settings['branches'] ?? [])->keyBy('id');
        $default = $settings['default_daily_sales_target'] ?? null;

        return collect($authorized)->map(function ($b) use ($byId, $default) {
            $own = $byId[$b['id']]['daily_sales_target'] ?? null;
            $target = $own ?? $default;

            return ['id' => $b['id'], 'name' => $b['name'], 'daily_target' => $target === null ? null : (float) $target];
        })->values()->all();
    }

    /** The owner's business settings (SharedReads::businessSettings); every value may be null = "Not set". */
    public function settings(): array
    {
        return app(SharedReads::class)->businessSettings();
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
