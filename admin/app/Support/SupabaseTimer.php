<?php

namespace App\Support;

/**
 * Counts Supabase round trips and the time spent in them during one request (for the
 * Server-Timing header and the timing log). Pure measurement: it never changes a query.
 */
final class SupabaseTimer
{
    public static int $calls = 0;
    public static float $ms = 0.0;
    /** [['fn' => name, 'ms' => float], ...] */
    public static array $log = [];
    public static bool $connected = false;
    public static float $connectMs = 0.0;

    public static function reset(): void
    {
        self::$calls = 0;
        self::$ms = 0.0;
        self::$log = [];
        self::$connected = false;
        self::$connectMs = 0.0;
    }

    /** First connection use in this request (TLS handshake unless the persistent connection is reused). */
    public static function connect(\Closure $open): mixed
    {
        $t = hrtime(true);
        try {
            return $open();
        } finally {
            self::$connected = true;
            self::$connectMs = round((hrtime(true) - $t) / 1e6, 1);
            self::$ms += self::$connectMs;
            self::$log[] = ['fn' => 'connect', 'ms' => self::$connectMs];
        }
    }

    /**
     * @template T
     * @param  \Closure(): T  $work
     * @return T
     */
    public static function measure(string $label, \Closure $work): mixed
    {
        $t = hrtime(true);
        try {
            return $work();
        } finally {
            $ms = (hrtime(true) - $t) / 1e6;
            self::$calls++;
            self::$ms += $ms;
            self::$log[] = ['fn' => $label, 'ms' => round($ms, 1)];
        }
    }

    /** "public.foo(" -> "foo"; anything else -> "sql". */
    public static function label(string $sql): string
    {
        if (str_contains($sql, 'json_build_object(\'p0\'') && preg_match_all('/public\.(\w+)\(/', $sql, $all)) {
            return 'batch['.implode('+', $all[1]).']';
        }

        return preg_match('/public\.(\w+)\(/', $sql, $m) ? $m[1] : 'sql';
    }
}
