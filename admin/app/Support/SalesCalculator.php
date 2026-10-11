<?php

namespace App\Support;

/**
 * Rating of a branch's sales against its (optional) target. The sales figure itself (net sales)
 * is computed by the database (public.sales_overview), never here.
 */
class SalesCalculator
{
    /**
     * low | average | high, using the owner's rating ratios (business_settings.sales_low_ratio /
     * sales_high_ratio). 'unrated' when either ratio is not set: nothing is compared against an
     * invented threshold.
     */
    public static function status(float $net, float $target, ?float $lowBelow, ?float $highAbove): string
    {
        if ($lowBelow === null || $highAbove === null) {
            return 'unrated';
        }
        $ratio = $target > 0 ? $net / $target : 0;
        return $ratio < $lowBelow ? 'low' : ($ratio > $highAbove ? 'high' : 'average');
    }
}
