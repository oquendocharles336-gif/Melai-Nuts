<?php

namespace App\Http\Middleware;

use App\Support\SupabaseTimer;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpFoundation\Response;

/**
 * TEMPORARY performance instrumentation (melai.timing, env MELAI_TIMING; off by default).
 *
 * Adds   Server-Timing: app;dur=<total ms>, supabase;dur=<ms>;desc="<n> calls"
 * (visible in the browser's DevTools → Network → Timing) and writes one line per request to
 * storage/logs/timing.log:  GET /dashboard 912ms · supabase 5 calls 640ms · get_my_staff_context 121, ...
 */
class ServerTiming
{
    public function handle(Request $request, Closure $next): Response
    {
        SupabaseTimer::reset();
        if (! config('melai.timing')) {
            return $next($request);
        }
        $start = defined('LARAVEL_START') && app()->runningInConsole() === false ? LARAVEL_START : microtime(true);
        $t = microtime(true);
        $response = $next($request);
        $total = (microtime(true) - min($start, $t)) * 1000;

        $response->headers->set('Server-Timing', sprintf('app;dur=%.0f, supabase;dur=%.0f;desc="%d calls"', $total, SupabaseTimer::$ms, SupabaseTimer::$calls), false);
        Log::channel('timing')->info(sprintf('%s /%s %dms · supabase %d calls %dms · %s',
            $request->method(), ltrim($request->path(), '/'), $total, SupabaseTimer::$calls, SupabaseTimer::$ms,
            implode(', ', array_map(fn ($l) => $l['fn'].' '.(int) $l['ms'], SupabaseTimer::$log))));

        return $response;
    }
}
