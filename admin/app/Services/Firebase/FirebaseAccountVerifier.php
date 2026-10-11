<?php

namespace App\Services\Firebase;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Validation\ValidationException;

/**
 * Proves that the person at the keyboard owns a Melai Nuts app account.
 *
 * The app signs staff and owners in with Firebase email + password. Here the website asks
 * Firebase Authentication itself (identitytoolkit accounts:signInWithPassword, over TLS,
 * server-to-server) whether those credentials are correct. Only Google's answer decides the
 * Firebase UID; nothing the browser sends is trusted as a UID. The password is used for this
 * one request and is never stored or logged.
 */
class FirebaseAccountVerifier
{
    private const ENDPOINT = 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword';

    public function configured(): bool
    {
        return filled(config('services.firebase.web_api_key'));
    }

    /** @return array{uid: string, email: string} */
    public function verify(string $email, string $password): array
    {
        if (! $this->configured()) {
            throw ValidationException::withMessages(['app_password' => 'App sign-in is not set up on this website yet (FIREBASE_WEB_API_KEY is empty). Ask the administrator.']);
        }

        try {
            $response = Http::timeout(15)->acceptJson()
                ->post(self::ENDPOINT.'?key='.urlencode(config('services.firebase.web_api_key')), [
                    'email' => $email, 'password' => $password, 'returnSecureToken' => true,
                ]);
        } catch (ConnectionException $e) {
            Log::warning('[firebase] sign-in check could not reach Firebase: '.$e->getMessage());
            throw ValidationException::withMessages(['app_password' => 'Could not reach the Melai Nuts app sign-in service. Please try again in a moment.']);
        }

        if ($response->failed()) {
            $code = (string) $response->json('error.message', '');
            Log::info('[firebase] sign-in check refused', ['code' => strtok($code, ' :')]); // never the password

            throw ValidationException::withMessages(['app_password' => match (true) {
                str_starts_with($code, 'USER_DISABLED') => 'That app account is disabled.',
                str_starts_with($code, 'TOO_MANY_ATTEMPTS') => 'Too many attempts on that app account. Wait a few minutes and try again.',
                str_starts_with($code, 'API_KEY'), str_starts_with($code, 'PROJECT_NOT_FOUND') => 'App sign-in is misconfigured on this website (check FIREBASE_WEB_API_KEY).',
                default => 'The app email or password is incorrect.',
            }]);
        }

        $uid = (string) $response->json('localId', '');
        $returnedEmail = mb_strtolower(trim((string) $response->json('email', '')));
        if ($uid === '' || $returnedEmail !== mb_strtolower(trim($email))) {
            throw ValidationException::withMessages(['app_password' => 'The app sign-in service returned an unexpected answer. Please try again.']);
        }

        return ['uid' => $uid, 'email' => $returnedEmail];
    }
}
