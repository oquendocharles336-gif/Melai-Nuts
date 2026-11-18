<?php

namespace App\Services\Auth;

use RuntimeException;

/** An e-mail code step that did not go through; the message is safe to show as-is. */
class EmailCodeException extends RuntimeException
{
    public function __construct(string $message, public readonly string $reason = 'refused', public readonly int $retryAfter = 0)
    {
        parent::__construct($message);
    }

    /** The visitor has to (re)do the security check. */
    public function needsCaptcha(): bool
    {
        return in_array($this->reason, ['captcha_required', 'captcha_invalid', 'captcha_unavailable'], true);
    }

    public function sessionEnded(): bool
    {
        return $this->reason === 'unauthorized';
    }
}
