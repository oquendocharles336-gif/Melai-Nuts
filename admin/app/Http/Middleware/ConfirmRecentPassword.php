<?php

namespace App\Http\Middleware;

use App\Services\ActivityLogger;
use App\Services\Auth\PasswordVerifier;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpFoundation\Response;

/**
 * Money and points actions (refund approve / complete / HitPay send, loyalty adjustments) need the
 * person's password again: the form sends `current_password`. Once confirmed it is not asked again
 * for config('melai.security.password_confirm_seconds') (default 5 minutes) in this session.
 */
class ConfirmRecentPassword
{
    public const SESSION_KEY = 'auth.password_confirmed_at';

    public function __construct(private PasswordVerifier $verifier) {}

    public static function recentlyConfirmed(Request $request): bool
    {
        $at = (int) $request->session()->get(self::SESSION_KEY, 0);

        return $at > 0 && time() - $at < (int) config('melai.security.password_confirm_seconds', 300);
    }

    public function handle(Request $request, Closure $next): Response
    {
        if (self::recentlyConfirmed($request)) {
            return $next($request);
        }
        $password = (string) $request->input('current_password', '');
        if ($password === '') {
            throw ValidationException::withMessages(['current_password' => 'Enter your password to confirm this action.']);
        }
        $key = 'confirm-password:'.$request->user()->getAuthIdentifier();
        if (RateLimiter::tooManyAttempts($key, 5)) {
            throw ValidationException::withMessages(['current_password' => 'Too many wrong passwords. Try again in '.RateLimiter::availableIn($key).' seconds.']);
        }
        if (! $this->verifier->check($request->user(), $password)) {
            RateLimiter::hit($key, 300);
            ActivityLogger::log('auth.password_confirm_failed', 'Wrong password when confirming an action', $request->user(), ['route' => $request->route()?->getName()]);
            throw ValidationException::withMessages(['current_password' => 'That password is not correct.']);
        }
        RateLimiter::clear($key);
        $request->session()->put(self::SESSION_KEY, time());

        return $next($request);
    }
}
