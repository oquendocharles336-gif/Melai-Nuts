<?php

namespace App\Support;

use App\Services\Shop\CustomerSession;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Validation\ValidationException;

/**
 * The sign-in panel on the shop homepage: the ONLY place anyone signs in (customers, staff,
 * owners, admins), creates an account, resets a password or asks for staff access.
 *
 * Each panel has its own address (/?panel=sign-in, ...), so links and "please sign in" redirects
 * open it directly. Every form in it sends `_panel`, so a failed submit comes back to the same
 * panel with its errors inside it.
 */
final class AuthPanel
{
    public const SIGN_IN = 'sign-in';
    public const CREATE_ACCOUNT = 'create-account';
    public const RESET_PASSWORD = 'reset-password';
    public const STAFF_ACCESS = 'staff-access';

    public const ALL = [self::SIGN_IN, self::CREATE_ACCOUNT, self::RESET_PASSWORD, self::STAFF_ACCESS];

    /** The homepage with this panel open. */
    public static function url(string $panel = self::SIGN_IN): string
    {
        return route('shop.home', ['panel' => in_array($panel, self::ALL, true) ? $panel : self::SIGN_IN]);
    }

    /** Send a failed form back to its panel (errors and typed values, never passwords, come along). */
    public static function back(ValidationException $e, string $panel): ValidationException
    {
        return $e->redirectTo(self::url($panel));
    }

    /** Nobody is signed in on this browser (no admin login, no shop sign-in): the panel may show. */
    public static function guest(): bool
    {
        return ! Auth::check() && ! app(CustomerSession::class)->check();
    }

    /** The panel to show open on this homepage request, or null when it starts closed. */
    public static function open(Request $request): ?string
    {
        if (! self::guest()) {
            return null;
        }
        $panel = $request->session()->getOldInput('_panel') ?? $request->query('panel');

        return is_string($panel) && in_array($panel, self::ALL, true) ? $panel : null;
    }
}
