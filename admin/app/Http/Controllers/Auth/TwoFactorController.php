<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Http\Middleware\EnsureTwoFactorPassed;
use App\Services\ActivityLogger;
use App\Services\Auth\PasswordVerifier;
use App\Services\Auth\Totp;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * Optional two-step sign-in (TOTP). Turn on: password -> key shown -> code confirms it -> 8 one-time
 * recovery codes shown once. Turn off: password + a current code (or a recovery code).
 */
class TwoFactorController extends Controller
{
    public function __construct(private PasswordVerifier $passwords) {}

    public function show(Request $request)
    {
        $user = $request->user();
        $pending = ! $user->hasTwoFactor() && filled($user->two_factor_secret) ? $user->two_factor_secret : null;

        return view('auth.two-factor', [
            'enabled' => $user->hasTwoFactor(),
            'pendingSecret' => $pending,
            'otpauth' => $pending ? Totp::uri(config('app.name', 'Melai Nuts Admin'), $user->email, $pending) : null,
            'recoveryCodes' => session('recovery_codes'),
            'remaining' => count($user->two_factor_recovery_codes ?? []),
        ]);
    }

    public function start(Request $request)
    {
        $user = $request->user();
        abort_if($user->hasTwoFactor(), 409);
        $this->requirePassword($request);
        $user->forceFill(['two_factor_secret' => Totp::generateSecret(), 'two_factor_confirmed_at' => null, 'two_factor_recovery_codes' => null])->save();

        return redirect()->route('two-factor.show');
    }

    public function confirm(Request $request)
    {
        $user = $request->user();
        abort_if($user->hasTwoFactor() || blank($user->two_factor_secret), 409);
        $code = (string) $request->validate(['code' => ['required', 'string', 'max:12']])['code'];
        $this->throttle($request);
        if (! Totp::verify($user->two_factor_secret, $code, 'u'.$user->id)) {
            $this->miss($request);
            throw ValidationException::withMessages(['code' => 'That code is not right. Check the time on your phone and try the newest code.']);
        }
        [$plain, $hashed] = $this->recoveryCodes();
        $user->forceFill(['two_factor_confirmed_at' => now(), 'two_factor_recovery_codes' => $hashed])->save();
        $request->session()->put(EnsureTwoFactorPassed::SESSION_KEY, $user->getAuthIdentifier());
        ActivityLogger::log('auth.two_factor_enabled', 'Turned on two-step sign-in', $user);

        return redirect()->route('two-factor.show')->with('recovery_codes', $plain)
            ->with('status', 'Two-step sign-in is on. Save the recovery codes below now: they are shown only once.');
    }

    public function disable(Request $request)
    {
        $user = $request->user();
        abort_unless($user->hasTwoFactor(), 409);
        $this->requirePassword($request);
        $code = (string) $request->validate(['code' => ['required', 'string', 'max:24']])['code'];
        $this->throttle($request);
        if (! $this->acceptCode($user, $code)) {
            $this->miss($request);
            throw ValidationException::withMessages(['code' => 'Enter a current code from your authenticator (or a recovery code).']);
        }
        $user->forceFill(['two_factor_secret' => null, 'two_factor_recovery_codes' => null, 'two_factor_confirmed_at' => null])->save();
        ActivityLogger::log('auth.two_factor_disabled', 'Turned off two-step sign-in', $user);

        return redirect()->route('two-factor.show')->with('status', 'Two-step sign-in is off.');
    }

    public function challenge(Request $request)
    {
        if (! $request->user()->hasTwoFactor()) {
            return redirect()->route('dashboard');
        }

        return view('auth.two-factor-challenge');
    }

    public function verify(Request $request)
    {
        $user = $request->user();
        if (! $user->hasTwoFactor()) {
            return redirect()->route('dashboard');
        }
        $code = (string) $request->validate(['code' => ['required', 'string', 'max:24']])['code'];
        $this->throttle($request);
        if (! $this->acceptCode($user, $code)) {
            $this->miss($request);
            ActivityLogger::log('auth.two_factor_failed', 'Wrong two-step sign-in code', $user);
            throw ValidationException::withMessages(['code' => 'That code is not right. Try the newest code, or a recovery code.']);
        }
        RateLimiter::clear($this->key($request));
        $request->session()->regenerate();
        $request->session()->put(EnsureTwoFactorPassed::SESSION_KEY, $user->getAuthIdentifier());
        ActivityLogger::log('auth.two_factor_passed', 'Passed two-step sign-in', $user);

        return redirect()->intended(route('dashboard'));
    }

    /** A TOTP code, or an unused recovery code (which is then used up). */
    private function acceptCode($user, string $code): bool
    {
        if (Totp::verify($user->two_factor_secret, $code, 'u'.$user->id)) {
            return true;
        }
        $normal = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $code));
        $codes = $user->two_factor_recovery_codes ?? [];
        foreach ($codes as $i => $hash) {
            if (Hash::check($normal, $hash)) {
                unset($codes[$i]);
                $user->forceFill(['two_factor_recovery_codes' => array_values($codes)])->save();
                ActivityLogger::log('auth.two_factor_recovery_used', 'Used a recovery code ('.count($codes).' left)', $user);

                return true;
            }
        }

        return false;
    }

    /** @return array{0: list<string>, 1: list<string>} [shown once, stored hashes] */
    private function recoveryCodes(): array
    {
        $plain = [];
        for ($i = 0; $i < 8; $i++) {
            $plain[] = strtoupper(Str::random(5).'-'.Str::random(5));
        }

        return [$plain, array_map(fn ($c) => Hash::make(str_replace('-', '', $c)), $plain)];
    }

    private function requirePassword(Request $request): void
    {
        $this->throttle($request);
        if (! $this->passwords->check($request->user(), (string) $request->input('current_password', ''))) {
            $this->miss($request);
            throw ValidationException::withMessages(['current_password' => 'That password is not correct.']);
        }
    }

    private function key(Request $request): string
    {
        return 'two-factor:'.$request->user()->getAuthIdentifier();
    }

    private function throttle(Request $request): void
    {
        if (RateLimiter::tooManyAttempts($this->key($request), 5)) {
            throw ValidationException::withMessages(['code' => 'Too many tries. Wait '.RateLimiter::availableIn($this->key($request)).' seconds.']);
        }
    }

    private function miss(Request $request): void
    {
        RateLimiter::hit($this->key($request), 300);
    }
}
