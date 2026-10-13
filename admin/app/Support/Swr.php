<?php

namespace App\Support;

use App\Services\AdminActions;
use Closure;
use Illuminate\Support\Facades\Cache;

/**
 * Stale-while-revalidate cache for database answers, ALWAYS scoped to one website login and its
 * linked app account (users.id + users.staff_uid): nothing is ever shared between accounts that
 * could see different branches.
 *
 *  - younger than $fresh seconds  → served from the cache
 *  - younger than $stale seconds  → served from the cache at once, marked stale: the response gets
 *    "X-Melai-Stale: 1" and the browser re-asks with ?fresh=1 in the background (works on any PHP
 *    server, including `php artisan serve`, where "after the response" work is not possible)
 *  - older, missing, ?fresh=1, or after any data change (AdminActions::version()) → loaded now
 *
 * Every key contains the global data version, so a mutation (order moved, stock received, refund,
 * payment, loyalty, product toggle, ...) makes every cached answer of every account obsolete at once.
 */
final class Swr
{
    /** True when this request served at least one stale value. */
    public static bool $servedStale = false;
    /** ?fresh=1 on the request: reload everything (set by App\Http\Middleware\ServerTiming). */
    public static bool $force = false;

    public static function reset(bool $force = false): void
    {
        self::$servedStale = false;
        self::$force = $force;
    }

    /**
     * @template T
     * @param  Closure(): T  $load
     * @return T
     */
    public static function remember(string $name, int $fresh, int $stale, Closure $load): mixed
    {
        if ($fresh <= 0 || ! self::enabled()) {
            return $load();
        }
        $key = self::key($name);
        $hit = self::$force ? null : Cache::get($key);
        if (is_array($hit) && array_key_exists('v', $hit)) {
            $age = now()->getTimestamp() - (int) $hit['at'];
            if ($age <= $fresh) {
                return $hit['v'];
            }
            if ($age <= max($fresh, $stale)) {
                self::$servedStale = true;

                return $hit['v'];
            }
        }
        $value = $load();
        Cache::put($key, ['at' => now()->getTimestamp(), 'v' => $value], max($fresh, $stale));

        return $value;
    }

    /** A usable (fresh or stale) cached value exists and will be served without a round trip. */
    public static function has(string $name): bool
    {
        if (self::$force || self::fresh() <= 0 || ! self::enabled()) {
            return false;
        }
        $hit = Cache::get(self::key($name));

        return is_array($hit) && now()->getTimestamp() - (int) $hit['at'] <= max(self::fresh(), self::stale());
    }

    /** Off for the automated tests' fixture data source (as before); on with the app's database. */
    public static function enabled(): bool
    {
        return app(\App\Services\Platform::class)->isSupabase();
    }

    /** melai:swr:<login+account+database hash>:<data version>:<name> */
    public static function key(string $name): string
    {
        return 'melai:swr:'.self::scope().':v'.AdminActions::version().':'.$name;
    }

    /** Hash of the signed-in login, its linked app account and the database answering. */
    public static function scope(): string
    {
        $user = auth()->user();

        return sha1(($user?->getAuthIdentifier() ?? '-').'|'.($user?->staff_uid ?? '-').'|'.self::target());
    }

    /**
     * Which Supabase database answers (host/port/database): switching admin/.env between the real
     * project and a local copy never serves one database's cached answers for the other.
     */
    public static function target(): string
    {
        $c = config('database.connections.'.config('melai.supabase.connection', 'supabase'), []);

        return ($c['url'] ?? '') ?: (($c['host'] ?? '').':'.($c['port'] ?? '').'/'.($c['database'] ?? ''));
    }

    public static function fresh(): int
    {
        return (int) config('melai.dashboard.cache_seconds', 45);
    }

    public static function stale(): int
    {
        return (int) config('melai.cache.stale_seconds', 300);
    }
}
