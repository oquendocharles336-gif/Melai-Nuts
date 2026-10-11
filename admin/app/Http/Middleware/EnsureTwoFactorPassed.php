<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * A login with two-step sign-in turned on must enter a code from its authenticator once per
 * session (after every password sign-in and every "remember me" return) before any page.
 *
 * Admin (owner) logins MUST have two-step sign-in (config melai.two_factor.required_for_admins):
 * until it is set up they can only open the setup page and sign out.
 */
class EnsureTwoFactorPassed
{
    public const SESSION_KEY = 'two_factor_passed_for';

    private const OPEN = ['two-factor.challenge', 'two-factor.verify', 'logout'];

    /** Pages an admin without two-step sign-in may still open: the setup flow and sign-out. */
    private const SETUP = ['two-factor.show', 'two-factor.start', 'two-factor.confirm', 'logout'];

    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
        if ($user && method_exists($user, 'isAdmin') && $user->isAdmin() && ! $user->hasTwoFactor()
            && config('melai.two_factor.required_for_admins', true)
            && ! in_array($request->route()?->getName(), self::SETUP, true)) {
            $message = 'Owner accounts must turn on two-step sign-in before using the website.';
            if ($request->expectsJson()) {
                return response()->json(['message' => $message], 423);
            }

            return redirect()->route('two-factor.show')->with('error', $message);
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
