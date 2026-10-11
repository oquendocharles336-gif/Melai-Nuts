<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/** Pages that only exist with the shared database; 404 only for the automated tests' fixtures (MockPlatform). */
class EnsureSupabase
{
    public function handle(Request $request, Closure $next): Response
    {
        abort_unless(app(\App\Services\Platform::class)->isSupabase(), 404);

        return $next($request);
    }
}
