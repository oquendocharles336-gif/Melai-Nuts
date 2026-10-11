<?php

namespace Database\Seeders;

use App\Models\User;
use App\Services\Auth\AdminEmailChanger;
use App\Exceptions\AccountLinkException;
use App\Services\Auth\AutoLinker;
use App\Services\Auth\LinkState;
use Illuminate\Database\Seeder;
use Illuminate\Validation\ValidationException;

class AdminSeeder extends Seeder
{
    public function run(): void
    {
        $cfg = config('melai.admin');
        if (blank($cfg['email']) || blank($cfg['password'])) {
            throw new \RuntimeException('Set ADMIN_EMAIL and ADMIN_PASSWORD in .env before seeding: the first admin login has no default credentials.');
        }

        $email = mb_strtolower(trim($cfg['email']));
        // The .env.example placeholder (owner@example.com) is never a real login outside the test suite.
        if (! app()->environment('testing') && preg_match('/@example\.(com|org|net)$/', $email)) {
            throw new \RuntimeException("ADMIN_EMAIL is still the placeholder {$email}. Put the owner's real app email in .env before seeding.");
        }

        // ADMIN_EMAIL changed? Then the existing "Melai Admin" login is renamed in place (same user,
        // password, role, access, history) instead of a second admin being created.
        if (! User::where('email', $email)->exists()) {
            $changer = app(AdminEmailChanger::class);
            try {
                $existing = $changer->findAdmin(null);
            } catch (ValidationException $e) {
                throw new \RuntimeException(collect($e->errors())->flatten()->first()
                    ." Run: php artisan melai:change-admin-email <old email> {$email}");
            }
            if ($existing) {
                try {
                    $r = $changer->change($existing, $email);
                } catch (ValidationException $e) {
                    throw new \RuntimeException("ADMIN_EMAIL changed to {$email}, but the existing admin {$existing->email} could not be updated: "
                        .collect($e->errors())->flatten()->first()." No second admin was created. Run: php artisan melai:change-admin-email {$existing->email} {$email}");
                }
                $this->command?->info("Admin email changed in place: {$r['old']} -> {$r['new']}.");
                if ($r['link_error']) {
                    $this->command?->warn('Not linked to the app owner: '.$r['link_error']);
                }
            }
        }

        $admin = User::firstOrNew(['email' => $email]);
        $admin->forceFill([
            'name' => $cfg['name'],
            'password' => $admin->exists ? $admin->password : $cfg['password'],
            'role' => User::ROLE_ADMIN,
            'is_active' => true,
            'has_access' => true,
        ])->save();

        // Link the admin to the owner's app account now (ADMIN_STAFF_UID, else the active owner row with
        // ADMIN_EMAIL), verified by Supabase. Every sign-in repeats this, so a failure here is only a warning.
        try {
            $r = app(AutoLinker::class)->linkServerSide($admin);
            if ($r['state'] === LinkState::LINKED) {
                $this->command?->info("Admin {$admin->email} acts as app owner \"{$r['profile']['full_name']}\" ({$r['profile']['firebase_uid']}).");
            }
        } catch (AccountLinkException $e) {
            $this->command?->warn('Admin not linked to the app owner yet: '.$e->getMessage());
        }
    }
}
