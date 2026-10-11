<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * A login with two-step sign-in turned on must enter a code from its authenticator once per
 * session (after every password sign-in and every "remember me" return) before any page.
 */
class EnsureTwoFactorPassed
{
    public const SESSION_KEY = 'two_factor_passed_for';

    private const OPEN = ['two-factor.challenge', 'two-factor.verify', 'logout'];

    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
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
