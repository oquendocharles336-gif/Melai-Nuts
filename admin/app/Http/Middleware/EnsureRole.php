<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;

class EnsureRole
{
    public function handle(Request $request, Closure $next, string ...$roles)
    {
        $user = $request->user();
        // Only website roles count, whatever a route lists (riders never use the website).
        abort_unless($user && $user->canUseWebsite() && in_array($user->role, $roles, true), 403);

        return $next($request);
    }
}
