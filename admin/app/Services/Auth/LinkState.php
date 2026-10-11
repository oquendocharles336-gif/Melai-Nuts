<?php

namespace App\Services\Auth;

/**
 * The states of "is this website login linked to a Melai Nuts app account?", each with what the
 * person should do next. AccountLinkStatus decides the state from the real backends
 * (Firebase session + Supabase staff registry); nothing here is ever assumed.
 */
final class LinkState
{
    public const CONFIG_MISSING = 'config_missing';
    public const NOT_AUTHENTICATED = 'not_authenticated';
    public const EMAIL_NOT_VERIFIED = 'email_not_verified';
    public const FIREBASE_ACCOUNT_MISSING = 'firebase_account_missing';
    public const PROFILE_MISSING = 'profile_missing';
    public const EMAIL_MISMATCH = 'email_mismatch';
    public const ROLE_NOT_AUTHORIZED = 'role_not_authorized';
    public const BRANCH_MISSING = 'branch_missing';
    public const LINKED = 'linked';
    public const TEMPORARY_ERROR = 'temporary_error';
    public const NOT_APPLICABLE = 'not_applicable';

    /** [title, badge css class, default instructions] */
    public static function describe(string $state): array
    {
        return match ($state) {
            self::CONFIG_MISSING => ['Configuration missing', 'low',
                'The website cannot talk to the Melai Nuts app sign-in service yet. The administrator must finish the Firebase settings in admin/.env (see INTEGRATION.md, section 2B).'],
            self::NOT_AUTHENTICATED => ['Sign in with your app account', 'info',
                'Business pages act as your Melai Nuts app account, so the website needs a current sign-in with that account. Enter your app email and password below. The password is checked by Firebase and is not stored.'],
            self::EMAIL_NOT_VERIFIED => ['Email not verified', 'low',
                'This website requires a verified email. Open the verification email Firebase sent to you (check spam), click the link, then sign in again.'],
            self::FIREBASE_ACCOUNT_MISSING => ['No app account', 'low',
                'Firebase has no Melai Nuts app account for this email (or the password is wrong). Staff and owners are registered by an owner in the app\'s User Management, or register on this website\'s Create Account page and wait for an owner to approve you.'],
            self::PROFILE_MISSING => ['App profile missing', 'low',
                'You are signed in with a real Melai Nuts app account, but it is not registered as staff or owner in the app\'s staff registry. An owner must approve this login on the website\'s Users page or register you in the app\'s User Management.'],
            self::EMAIL_MISMATCH => ['Email does not match', 'low',
                'The app account you signed in with does not belong to this website login (different email or already linked to another app account). Sign out and sign in with the matching account, or ask an admin to unlink the old link on the Users page.'],
            self::ROLE_NOT_AUTHORIZED => ['Role not authorized', 'low',
                'The app account is not allowed to use this login: admin logins need an active owner account, staff logins an active staff account. Ask the owner to fix the account in the app\'s User Management.'],
            self::BRANCH_MISSING => ['No branch assigned', 'low',
                'Your staff account has no valid branch in the app. An owner must assign your branch in the app\'s User Management.'],
            self::LINKED => ['Linked', 'high', ''],
            self::TEMPORARY_ERROR => ['Temporarily unavailable', 'low',
                'The app sign-in service or the database could not be reached just now. Nothing was changed. Please try again in a moment.'],
            default => ['Not applicable', 'info', 'This login cannot use the website, so it is not linked. Riders sign in to the Melai Nuts app.'],
        };
    }
}
