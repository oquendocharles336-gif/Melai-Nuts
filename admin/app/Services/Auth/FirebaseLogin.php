<?php

namespace App\Services\Auth;

use App\Exceptions\AccountLinkException;
use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseTokenVerifier;
use App\Services\Supabase\StaffIdentity;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

/**
 * Website sign-in with a Melai Nuts app account (Firebase email + password).
 *
 *  1. Firebase checks the password and returns an ID token; FirebaseTokenVerifier checks it
 *     (Google signature, this project, not expired). Only that token decides the UID.
 *  2. The website login for that UID is found, or the login with the same (normalised) email is
 *     bound to it. From then on that login signs in only through Firebase.
 *  3. With no website login yet, one is created ONLY for an account the app's staff registry
 *     (Supabase) reports as an active owner (-> admin login) or staff member with a branch
 *     (-> staff login). Anything else is refused with the precise reason; nothing is created.
 *  4. LoginController then links the login to its staff/owner row (AutoLinker) before the
 *     person is signed in, so nobody ever has to link an account by hand.
 */
class FirebaseLogin
{
    public function __construct(
        private FirebaseConfig $config,
        private FirebaseAuthClient $client,
        private FirebaseTokenVerifier $verifier,
        private StaffIdentity $identity,
        private AccountLinkStatus $status,
    ) {}

    /**
     * @return array{0: User, 1: array, 2: array} [user, tokens, claims]
     * @throws \App\Services\Firebase\FirebaseAuthException|AccountLinkException
     */
    public function attempt(string $email, string $password, ?User $expected = null): array
    {
        $tokens = $this->client->signIn($email, $password);
        $claims = $this->verifier->verify($tokens['id_token']);

        return [$this->resolveUser($claims, $email, $expected), $tokens, $claims];
    }

    /** Find / bind / create the website login for verified Firebase $claims. */
    public function resolveUser(array $claims, string $typedEmail, ?User $expected = null, bool $allowCreate = true): User
    {
        $email = $this->norm($claims['email']);
        if ($email === '' || $email !== $this->norm($typedEmail)) {
            throw new AccountLinkException(LinkState::EMAIL_MISMATCH, 'The app sign-in service returned a different email than the one entered. Nothing was linked.');
        }
        if ($this->config->requireVerifiedEmail() && ! $claims['email_verified']) {
            throw new AccountLinkException(LinkState::EMAIL_NOT_VERIFIED, LinkState::describe(LinkState::EMAIL_NOT_VERIFIED)[2]);
        }

        $user = DB::transaction(function () use ($claims, $email, $expected) {
            $user = User::where('firebase_uid', $claims['sub'])->lockForUpdate()->first();
            if (! $user && ($byEmail = User::where('email', $email)->lockForUpdate()->first())) {
                if (filled($byEmail->firebase_uid)) {
                    throw new AccountLinkException(LinkState::EMAIL_MISMATCH, 'This website login already signs in with a different app account. Ask an admin to check it on the Users page.');
                }
                if (filled($byEmail->staff_uid) && $byEmail->staff_uid !== $claims['sub']) {
                    throw new AccountLinkException(LinkState::EMAIL_MISMATCH, 'This website login is linked to a different app account. An admin can unlink it on the Users page.');
                }
                // Bind: the person proved they own the Firebase account with this login's email. The old
                // local password stops working, so whoever created the login cannot use it any more.
                $byEmail->forceFill(['firebase_uid' => $claims['sub'], 'password' => Hash::make(Str::random(64))])->save();
                ActivityLogger::log('account.firebase_bound', "Website login {$byEmail->email} now signs in with its Melai Nuts app account", $byEmail, ['firebase_uid' => $claims['sub']]);
                $user = $byEmail;
            }
            if ($expected && (! $user || ! $user->is($expected))) {
                throw new AccountLinkException(LinkState::EMAIL_MISMATCH, 'That app account belongs to another website login. Nothing was linked.');
            }

            return $user;
        });

        $user ??= $allowCreate ? $this->createFromAppAccount($claims) : throw new AccountLinkException(LinkState::PROFILE_MISSING, LinkState::describe(LinkState::PROFILE_MISSING)[2]);

        if ($user->firebase_email_verified !== $claims['email_verified']) {
            $user->forceFill(['firebase_email_verified' => $claims['email_verified']])->save();
        }

        return $user;
    }

    /** Creates a login only for a verified active owner / staff account of the app. */
    private function createFromAppAccount(array $claims): User
    {
        try {
            $ctx = $this->identity->contextFor($claims['sub']);
        } catch (BackendUnavailableException|BackendActionException $e) {
            throw new AccountLinkException(LinkState::TEMPORARY_ERROR, $e->getMessage());
        }
        $profile = $ctx['profile'] ?? null;
        match ($ctx['status'] ?? 'not_provisioned') {
            'active' => null,
            'invalid_branch' => throw new AccountLinkException(LinkState::BRANCH_MISSING, LinkState::describe(LinkState::BRANCH_MISSING)[2]),
            'not_provisioned' => throw new AccountLinkException(LinkState::PROFILE_MISSING, $this->notRegisteredMessage($claims)),
            default => throw new AccountLinkException(LinkState::ROLE_NOT_AUTHORIZED, $this->identity->statusMessage($ctx['status'])),
        };
        if ($this->norm($profile['email'] ?? '') !== $this->norm($claims['email'])) {
            throw new AccountLinkException(LinkState::EMAIL_MISMATCH, "The app's staff registry has this account under {$profile['email']}. Ask the owner to correct the email in the app.");
        }

        try {
            $user = (new User)->forceFill([
                'name' => filled($profile['full_name'] ?? null) ? $profile['full_name'] : $claims['email'],
                'email' => $this->norm($claims['email']),
                'password' => Hash::make(Str::random(64)), // never used: Firebase holds the password
                'role' => $profile['role'] === 'owner' ? User::ROLE_ADMIN : User::ROLE_STAFF,
                'is_active' => true,
                'has_access' => false, // granted by AccountLinkStatus once the link is verified
                'firebase_uid' => $claims['sub'],
                'firebase_email_verified' => $claims['email_verified'],
            ]);
            $user->save();
        } catch (UniqueConstraintViolationException) {
            throw new AccountLinkException(LinkState::TEMPORARY_ERROR, 'This account was just set up by another request. Please sign in again.');
        }

        $result = $this->status->evaluate($user, $claims, link: true);
        if ($result['state'] !== LinkState::LINKED) {
            $user->delete(); // never leave a half-created login behind
            throw new AccountLinkException($result['state'], $result['message']);
        }
        ActivityLogger::log('account.created_from_app', "Website login created for app {$profile['role']} {$user->email}", $user, ['firebase_uid' => $claims['sub']]);

        return $user->fresh();
    }

    /** No staff row for this Firebase UID: the e-mail of the token is checked too, so the reason is precise. */
    private function notRegisteredMessage(array $claims): string
    {
        return $this->status->registeredUnderAnotherUid($claims)
            ?? 'Your Melai Nuts app account is not registered as staff or owner, so it cannot use the admin website. '
            .'New staff: use Create Account on this website and wait for an owner to approve you, or ask an owner to register you in the app\'s User Management.';
    }

    private function norm(?string $email): string
    {
        return mb_strtolower(trim((string) $email));
    }
}
