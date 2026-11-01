<?php

namespace App\Support;

/**
 * Display helpers shared by every page (one definition instead of one per view). Every view gets
 * them as $peso, $pesoWhole and $methodLabel (App\Providers\AppServiceProvider, View::share).
 */
final class Format
{
    public const METHODS = [
        'cod' => 'COD', 'cash' => 'Cash', 'gcash' => 'GCash', 'maya' => 'Maya', 'card' => 'Card',
        'qrph' => 'QR Ph', 'grabpay' => 'GrabPay', 'shopeepay' => 'ShopeePay', 'spaylater' => 'SPayLater',
        'billease' => 'BillEase', 'wechat' => 'WeChat Pay', 'unionbank' => 'UnionBank Online',
        'instapay' => 'InstaPay', 'pesonet' => 'PESONet', 'bayad' => 'Bayad Center', 'ecpay' => 'ECPay',
        'palawan' => 'Palawan Pawnshop', 'online' => 'Online',
    ];

    /** ₱1,234.50; null (unknown) shows $none. */
    public static function peso(mixed $n, int $decimals = 2, string $none = '—'): string
    {
        return $n === null ? $none : '₱'.number_format((float) $n, $decimals);
    }

    /** Payment method label from METHODS (anything else in capitals). */
    public static function method(?string $m): string
    {
        return self::METHODS[$m] ?? strtoupper((string) $m);
    }
}
