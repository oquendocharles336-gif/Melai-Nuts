<?php

namespace App\Support;

/**
 * Display helpers shared by every page (one definition instead of one per view). Every view gets
 * them as $peso, $pesoWhole and $methodLabel (App\Providers\AppServiceProvider, View::share).
 */
final class Format
{
    public const METHODS = ['cod' => 'COD', 'cash' => 'Cash', 'gcash' => 'GCash', 'maya' => 'Maya', 'card' => 'Card'];

    /** ₱1,234.50; null (unknown) shows $none. */
    public static function peso(mixed $n, int $decimals = 2, string $none = '—'): string
    {
        return $n === null ? $none : '₱'.number_format((float) $n, $decimals);
    }

    /** Payment method label: COD, Cash, GCash, Maya, Card (anything else in capitals). */
    public static function method(?string $m): string
    {
        return self::METHODS[$m] ?? strtoupper((string) $m);
    }
}
