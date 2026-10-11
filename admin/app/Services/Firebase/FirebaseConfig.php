<?php

namespace App\Services\Firebase;

/**
 * Firebase Authentication settings of the Melai Nuts app (project in ../.firebaserc), read from .env.
 *
 *   FIREBASE_WEB_API_KEY   required  public Web API key of the app's Firebase project
 *   FIREBASE_PROJECT_ID    required  the Firebase project ID (same as ../.firebaserc); ID tokens must be issued for it
 *   FIREBASE_REQUIRE_VERIFIED_EMAIL  optional (default false)
 *
 * The API key only identifies the project for Identity Toolkit requests. It does not create,
 * sign in or link anybody by itself; the ID token Firebase returns (checked against Google's
 * public keys and FIREBASE_PROJECT_ID) is what proves who the user is.
 */
class FirebaseConfig
{
    public function apiKey(): ?string
    {
        $v = trim((string) config('services.firebase.web_api_key'));

        return $v === '' ? null : $v;
    }

    public function projectId(): ?string
    {
        $v = trim((string) config('services.firebase.project_id'));

        return $v === '' ? null : $v;
    }

    public function requireVerifiedEmail(): bool
    {
        return (bool) config('services.firebase.require_verified_email', false);
    }

    /** Names of the required .env variables that are empty. */
    public function missing(): array
    {
        return array_values(array_filter([
            $this->apiKey() === null ? 'FIREBASE_WEB_API_KEY' : null,
            $this->projectId() === null ? 'FIREBASE_PROJECT_ID' : null,
        ]));
    }

    public function ready(): bool
    {
        return $this->missing() === [];
    }

    /** Human message naming exactly what is missing and where to find it. */
    public function missingMessage(): string
    {
        $missing = $this->missing();
        if ($missing === []) {
            return '';
        }

        return 'Signing in with the Melai Nuts app account is not configured on this website: '
            .implode(' and ', $missing).(count($missing) > 1 ? ' are' : ' is').' empty in admin/.env. '
            .'Firebase console > Project settings > General: "Web API key" goes in FIREBASE_WEB_API_KEY and "Project ID" '
            .'in FIREBASE_PROJECT_ID (the same project as ../.firebaserc). Then run: php artisan config:clear && php artisan melai:firebase-check';
    }
}
