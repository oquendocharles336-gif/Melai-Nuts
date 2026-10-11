<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * A STAFF login with two-step sign-in turned on must enter a code from its authenticator once per
 * session (after every password sign-in and every "remember me" return) before any page.
 *
 * Admin (owner) logins never use two-step sign-in: they go straight in after the password.
 */
class EnsureTwoFactorPassed
{
    public const SESSION_KEY = 'two_factor_passed_for';

    private const OPEN = ['two-factor.challenge', 'two-factor.verify', 'logout'];

    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
        if ($user && method_exists($user, 'isAdmin') && $user->isAdmin()) {
            // No two-step sign-in for admins: no code after the password, and no setup pages.
            if (str_starts_with((string) $request->route()?->getName(), 'two-factor.')) {
                return redirect()->route('dashboard');
            }

            return $next($request);
        }
        if ($user && $user->hasTwoFactor()
            && $request->session()->get(self::SESSION_KEY) !== $user->getAuthIdentifier()
            && ! in_array($request->route()?->getName(), self::OPEN, true)) {
            if ($request->expectsJson()) {
                return response()->json(['message' => 'Enter your two-step sign-in code first.'], 423);
            }
            $request->session()->put('url.intended', $request->fullUrl());

            return redirect()->route('two-factor.challenge');
        }

        return $next($request);
    }
}
