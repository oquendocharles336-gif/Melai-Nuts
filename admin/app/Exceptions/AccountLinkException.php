<?php

namespace App\Exceptions;

use RuntimeException;

/** The login cannot act as a Melai Nuts app account; $state is one of App\Services\Auth\LinkState. */
class AccountLinkException extends RuntimeException
{
    public function __construct(public readonly string $state, string $message, ?\Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
    }
}
