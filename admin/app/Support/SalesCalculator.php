<?php

namespace App\Support;

/**
 * Rating of a branch's sales against its (optional) target. The sales figure itself (net sales)
 * is computed by the database (public.sales_overview), never here.
 */
class SalesCalculator
{
    /** low | average | high, using thresholds from config('melai.sales'). */
    public static function status(float $net, float $target, ?float $lowBelow = null, ?float $highAbove = null): string
    {
        $lowBelow ??= config('melai.sales.low_below');
        $highAbove ??= config('melai.sales.high_above');
        $ratio = $target > 0 ? $net / $target : 0;
        return $ratio < $lowBelow ? 'low' : ($ratio > $highAbove ? 'high' : 'average');
    }
}
