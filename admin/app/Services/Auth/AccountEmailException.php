<?php

namespace App\Services\Auth;

use RuntimeException;

/** An answer of the account-email function, with its stable code (see AccountEmails::message). */
class AccountEmailException extends RuntimeException
{
    public function __construct(string $message, public readonly string $reason = 'failed', public readonly int $retryAfter = 0)
    {
        parent::__construct($message);
    }

    /** The link itself is the problem (used / expired / not ours): ask for a new one. */
    public function isLinkProblem(): bool
    {
        return in_array($this->reason, ['link_used', 'link_expired', 'link_invalid'], true);
    }
}
