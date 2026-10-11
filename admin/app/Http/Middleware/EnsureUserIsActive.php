<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;

class EnsureUserIsActive
{
    public function handle(Request $request, Closure $next)
    {
        // A session of a login whose role may not use the website (e.g. an old rider login) ends here.
        if ($request->user() && ! $request->user()->canUseWebsite()) {
            Auth::logout();
            $request->session()->invalidate();
            $request->session()->regenerateToken();

            return redirect()->route('login')
                ->withErrors(['auth' => \App\Http\Controllers\Auth\LoginController::APP_ONLY_MESSAGE]);
        }

        if ($request->user() && ! $request->user()->is_active) {
            Auth::logout();
            $request->session()->invalidate();
            $request->session()->regenerateToken();

            return redirect()->route('login')
                ->withErrors(['auth' => 'This account has been deactivated. Contact an administrator.']);
        }

        return $next($request);
    }
}
