<?php

namespace App\Console\Commands;

use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use Illuminate\Console\Command;

/**
 * Checks the website's Firebase settings against the real Firebase project, without signing
 * anyone in or creating anything:
 *   1. FIREBASE_WEB_API_KEY and FIREBASE_PROJECT_ID are set;
 *   2. the project matches the app's (../.firebaserc), if that file is present;
 *   3. Firebase accepts the key, and the key belongs to FIREBASE_PROJECT_ID.
 *
 *   php artisan melai:firebase-check
 */
class FirebaseCheckCommand extends Command
{
    protected $signature = 'melai:firebase-check';

    protected $description = 'Verify the Firebase Authentication settings (FIREBASE_WEB_API_KEY / FIREBASE_PROJECT_ID) of the admin website';

    public function handle(FirebaseConfig $config, FirebaseAuthClient $client): int
    {
        if (! $config->ready()) {
            $this->error($config->missingMessage());

            return self::FAILURE;
        }
        $this->line('FIREBASE_PROJECT_ID  = '.$config->projectId());
        $this->line('FIREBASE_WEB_API_KEY = '.substr((string) $config->apiKey(), 0, 6).'… (set)');

        $rc = (string) config('services.firebase.firebaserc_path', base_path('../.firebaserc')); // tests point this elsewhere
        if (is_file($rc)) {
            $appProject = json_decode((string) file_get_contents($rc), true)['projects']['default'] ?? null;
            if ($appProject && $appProject !== $config->projectId()) {
                $this->error("The Melai Nuts app uses Firebase project \"{$appProject}\" (../.firebaserc), but FIREBASE_PROJECT_ID is \"{$config->projectId()}\".");

                return self::FAILURE;
            }
        }

        try {
            $keyProject = $client->projectIdOfApiKey();
        } catch (FirebaseAuthException $e) {
            $this->error($e->getMessage());

            return self::FAILURE;
        }
        // Google may answer with the project NUMBER (a 12-digit number) instead of the project ID.
        // A number can't be compared with the ID here; the real check is the "aud" of every ID token.
        if (ctype_digit($keyProject)) {
            $this->info("OK: Firebase accepts the Web API key (project number {$keyProject}).");
            $this->line('The project ID is checked on every sign-in (ID token "aud" must be '.$config->projectId().').');
            $this->line('Remember: Authentication > Sign-in method must have Email/Password enabled (php artisan cannot check that).');

            return self::SUCCESS;
        }
        if ($keyProject !== '' && $keyProject !== $config->projectId()) {
            $this->error("FIREBASE_WEB_API_KEY belongs to Firebase project \"{$keyProject}\", not \"{$config->projectId()}\". Use the Web API key of the app's project.");

            return self::FAILURE;
        }

        $this->info('OK: Firebase accepts the Web API key and it belongs to project '.($keyProject ?: $config->projectId()).'.');
        $this->line('Remember: Authentication > Sign-in method must have Email/Password enabled (php artisan cannot check that).');

        return self::SUCCESS;
    }
}
