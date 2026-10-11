<?php

namespace App\Services\Auth;

use App\Models\User;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseTokenVerifier;
use Illuminate\Support\Facades\Hash;

/**
 * Checks the signed-in person's password again (before refunds, points adjustments, turning off
 * two-step sign-in). App accounts are checked by Firebase (the token must be for the SAME UID);
 * website-only logins by their local hash. The password is never stored or logged.
 */
class PasswordVerifier
{
    public function __construct(private FirebaseConfig $config, private FirebaseAuthClient $client, private FirebaseTokenVerifier $verifier) {}

    public function check(User $user, string $password): bool
    {
        if ($password === '') {
            return false;
        }
        if ($user->usesFirebase()) {
            if (! $this->config->ready()) {
                return false;
            }
            try {
                $tokens = $this->client->signIn($user->email, $password);
                $claims = $this->verifier->verify($tokens['id_token']);
            } catch (FirebaseAuthException) {
                return false;
            }

            return hash_equals((string) $user->firebase_uid, (string) ($claims['sub'] ?? $claims['user_id'] ?? ''));
        }

        return Hash::check($password, (string) $user->password);
    }
}
