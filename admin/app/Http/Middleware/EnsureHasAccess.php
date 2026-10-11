<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;

class EnsureHasAccess
{
    public function handle(Request $request, Closure $next)
    {
        if (! $request->user()?->has_access) {
            return redirect()->route('waiting');
        }

        return $next($request);
    }
}
