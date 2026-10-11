<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Exceptions\ThrottleRequestsException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Symfony\Component\HttpFoundation\Response;

/**
 * Rate limit for every change (POST / PUT / PATCH / DELETE): melai.write_limit_per_minute per
 * signed-in login, or per IP address for guests. Reads (GET / HEAD) are not counted. Single routes
 * keep their own, tighter throttle:… limits from routes/web.php on top of this one.
 * Over the limit: HTTP 429 with Retry-After (resources/views/errors/429.blade.php).
 */
class ThrottleWrites
{
    public function handle(Request $request, Closure $next): Response
    {
        if ($request->isMethodSafe()) {
            return $next($request);
        }
        $max = max(1, (int) config('melai.write_limit_per_minute', 60));
        $key = 'writes:'.($request->user()?->getAuthIdentifier() ?? 'ip:'.$request->ip());
        if (RateLimiter::tooManyAttempts($key, $max)) {
            $seconds = RateLimiter::availableIn($key);
            throw new ThrottleRequestsException(
                "Too many changes in a short time. Please wait {$seconds} seconds and try again.",
                null,
                ['Retry-After' => $seconds],
            );
        }
        RateLimiter::hit($key, 60);

        return $next($request);
    }
}
