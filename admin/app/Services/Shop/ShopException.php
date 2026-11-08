<?php

namespace App\Services\Shop;

use RuntimeException;
use Throwable;

/**
 * A shop failure whose message is safe to show a customer as-is (no SQL, no internals).
 *
 * reason: offline | server | session | refused | not_configured | not_customer | unverified
 */
class ShopException extends RuntimeException
{
    public function __construct(string $message, public readonly string $reason = 'refused', public readonly int $status = 0, ?Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
    }

    public function sessionEnded(): bool
    {
        return $this->reason === 'session';
    }
}
