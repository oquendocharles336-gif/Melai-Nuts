<?php

namespace App\Console\Commands;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Models\User;
use App\Services\Supabase\StaffLinker;
use Illuminate\Console\Command;
use Illuminate\Validation\ValidationException;

/**
 * Bootstrap / repair tool: link an admin-portal login to its Melai Nuts app account.
 * Usually needed once, for the first admin (after that, admins link users on the Users page).
 *
 *   php artisan melai:link-staff kanzeki69@gmail.com <owner firebase uid>
 *   php artisan melai:link-staff kanzeki69@gmail.com --unlink
 */
class LinkStaffCommand extends Command
{
    protected $signature = 'melai:link-staff {email : Email of the admin-portal login} {uid? : Firebase UID of the staff/owner account in the app} {--unlink : Remove the link instead}';

    protected $description = 'Link an admin-portal login to its staff/owner account in the Melai Nuts app (Supabase)';

    public function handle(StaffLinker $linker): int
    {
        $user = User::where('email', mb_strtolower(trim($this->argument('email'))))->first();
        if (! $user) {
            $this->error('No admin-portal login with that email.');

            return self::FAILURE;
        }

        if ($this->option('unlink')) {
            $linker->unlink($user);
            $this->info("Unlinked {$user->email}.");

            return self::SUCCESS;
        }

        if (blank($this->argument('uid'))) {
            $this->error('Give the Firebase UID to link (Firebase console > Authentication > Users > User UID).');

            return self::FAILURE;
        }

        try {
            $profile = $linker->link($user, $this->argument('uid'));
        } catch (ValidationException $e) {
            $this->error(collect($e->errors())->flatten()->first());

            return self::FAILURE;
        } catch (BackendActionException|BackendUnavailableException $e) {
            $this->error($e->getMessage());

            return self::FAILURE;
        }

        $this->info("Linked {$user->email} to {$profile['role']} account \"{$profile['full_name']}\"".
            (($profile['branch_name'] ?? null) ? " ({$profile['branch_name']})" : '').'.');

        return self::SUCCESS;
    }
}
