<?php

namespace App\Services\Auth;

use RuntimeException;

/** A Turnstile token that was refused (or could not be checked). The message is customer-facing. */
class TurnstileException extends RuntimeException
{
    public function __construct(string $message, public readonly string $reason)
    {
        parent::__construct($message);
    }
}
