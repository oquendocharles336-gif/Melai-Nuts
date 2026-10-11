<?php

namespace App\Services\Firebase;

use RuntimeException;

/**
 * A refusal or failure from Firebase Authentication, with a stable reason the callers branch on.
 * Messages are safe to show; passwords and tokens never appear in them.
 */
class FirebaseAuthException extends RuntimeException
{
    public const INVALID_CREDENTIALS = 'invalid_credentials'; // wrong password, or (with enumeration protection) no such account
    public const ACCOUNT_NOT_FOUND = 'account_not_found';     // Firebase says the email has no account
    public const EMAIL_EXISTS = 'email_exists';
    public const WEAK_PASSWORD = 'weak_password';
    public const INVALID_EMAIL = 'invalid_email';
    public const USER_DISABLED = 'user_disabled';
    public const TOO_MANY_ATTEMPTS = 'too_many_attempts';
    public const SESSION_ENDED = 'session_ended';             // refresh token revoked / expired / user deleted
    public const INVALID_TOKEN = 'invalid_token';             // ID token signature / project / expiry check failed
    public const CONFIG = 'config';                           // missing or wrong key / project / provider disabled
    public const NETWORK = 'network';                         // Firebase could not be reached
    public const UNEXPECTED = 'unexpected';

    public function __construct(public readonly string $reason, string $message, public readonly ?string $firebaseCode = null)
    {
        parent::__construct($message);
    }

    public function isCredentialError(): bool
    {
        return in_array($this->reason, [self::INVALID_CREDENTIALS, self::ACCOUNT_NOT_FOUND], true);
    }

    /** Problems on Firebase's side or ours that are not the user's fault and may go away. */
    public function isTemporary(): bool
    {
        return in_array($this->reason, [self::NETWORK, self::UNEXPECTED], true);
    }
}
