<?php

namespace App\Console\Commands;

use App\Services\Auth\AdminEmailChanger;
use Illuminate\Console\Command;
use Illuminate\Validation\ValidationException;

/**
 * Change the email of the existing "Melai Admin" login IN PLACE (same user id; password, role,
 * access and activity history kept), then link it to the app's active owner with the new email.
 *
 *   php artisan melai:change-admin-email old@example.com owner@example.com
 *   php artisan melai:change-admin-email old@example.com owner@example.com --uid=<owner firebase uid>
 *
 * If no login has the old email, the single admin named ADMIN_NAME ("Melai Admin") is used.
 * Afterwards set ADMIN_EMAIL to the new email in .env.
 */
class ChangeAdminEmailCommand extends Command
{
    protected $signature = 'melai:change-admin-email
        {old : Current email of the admin login (falls back to the admin named "Melai Admin")}
        {new : New email}
        {--uid= : Firebase UID of the owner account to link (found automatically when empty)}
        {--skip-link : Change the email even if Supabase cannot be reached (link later with melai:link-staff)}';

    protected $description = 'Change the existing admin login\'s email in place and re-link it to the app owner account';

    public function handle(AdminEmailChanger $changer): int
    {
        try {
            $admin = $changer->findAdmin($this->argument('old'));
            if (! $admin) {
                $this->error('No admin login with that email, and no admin named "'.(config('melai.admin.name') ?: 'Melai Admin').'". Nothing was changed.');

                return self::FAILURE;
            }
            $r = $changer->change($admin, $this->argument('new'), $this->option('uid'), (bool) $this->option('skip-link'));
        } catch (ValidationException $e) {
            $this->error(collect($e->errors())->flatten()->first());

            return self::FAILURE;
        }

        $this->info("Admin email changed: {$r['old']} -> {$r['new']} (user id {$r['user']->id}, role {$r['user']->role}).");
        foreach ($r['cleared'] as $c) {
            $this->line("  cleared {$c}: it belonged to an app account with another email");
        }
        $this->line('  sessions signed out: '.($r['sessions'] ?? 'n/a (session driver is not "database"; remember-me tokens were rotated)'));

        if ($r['linked']) {
            $this->info("Linked to app owner \"{$r['linked']['full_name']}\" (staff_uid {$r['linked']['firebase_uid']}); get_my_staff_context() status: active.");
        } elseif ($r['link_error']) {
            $this->warn('Not linked: '.$r['link_error']);
            $this->line("  Fix it in the app / Supabase, then run: php artisan melai:link-staff {$r['new']} <owner firebase uid>");
        }
        if (mb_strtolower((string) config('melai.admin.email')) !== $r['new']) {
            $this->warn("Now set ADMIN_EMAIL={$r['new']} in .env (it is still ".(config('melai.admin.email') ?: 'empty').').');
        }

        return self::SUCCESS;
    }
}
