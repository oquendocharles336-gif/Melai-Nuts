<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Http\Requests\Rules;
use App\Services\ActivityLogger;
use App\Services\Auth\AccountEmailException;
use App\Services\Auth\AccountEmails;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Shop\CustomerSession;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Validation\ValidationException;

/**
 * "Change email" on the website (staff / owner Settings, and the shop's Your account). The current
 * password is checked with Firebase first (a fresh sign-in, so the change needs the password, not
 * just an open session), then the account-email function e-mails a confirmation link to the NEW
 * address and a "was this you?" notice to the OLD one. Nothing changes until the link is opened.
 */
class EmailChangeController extends Controller
{
    public function __construct(private AccountEmails $emails, private FirebaseAuthClient $firebase) {}

    /** Settings (staff / owner app account). */
    public function staff(Request $request)
    {
        $user = $request->user();
        abort_unless($user && $user->usesFirebase(), 403, 'This login has no Melai Nuts app account.');
        $message = $this->request($request, (string) $user->email, 'email-change:staff:'.$user->getAuthIdentifier());
        ActivityLogger::log('auth.email_change_requested', 'Asked to change the account email (confirmation sent to the new address)', $user);

        return redirect()->route('settings')->with('status', $message);
    }

    /** Shop > Your account (customer). */
    public function customer(Request $request, CustomerSession $customer)
    {
        abort_unless($customer->check(), 403);
        $message = $this->request($request, $customer->email(), 'email-change:customer:'.$customer->uid());

        return redirect()->route('shop.account')->with('shop_status', $message);
    }

    private function request(Request $request, string $currentEmail, string $limiterKey): string
    {
        $data = $request->validate([
            'new_email' => ['required', 'email', 'max:'.Rules::EMAIL_MAX],
            'current_password' => ['required', 'string', 'max:128'],
        ], ['current_password.required' => 'Enter your current password.']);
        if (mb_strtolower(trim($data['new_email'])) === mb_strtolower($currentEmail)) {
            throw ValidationException::withMessages(['new_email' => 'That is already your email address.']);
        }
        if (RateLimiter::tooManyAttempts($limiterKey, 5)) {
            throw ValidationException::withMessages(['current_password' => 'Too many wrong passwords. Try again in '.RateLimiter::availableIn($limiterKey).' seconds.']);
        }
        try {
            $tokens = $this->firebase->signIn($currentEmail, $data['current_password']);
        } catch (FirebaseAuthException $e) {
            if ($e->isCredentialError()) {
                RateLimiter::hit($limiterKey, 300);
                throw ValidationException::withMessages(['current_password' => 'That password is not correct.']);
            }
            throw ValidationException::withMessages(['current_password' => $e->getMessage()]);
        }
        RateLimiter::clear($limiterKey);
        try {
            return $this->emails->requestEmailChange($tokens['id_token'], $data['new_email'], $request->ip())
                ?: 'We sent a confirmation link to the new address. Your email changes after you open it.';
        } catch (AccountEmailException $e) {
            throw ValidationException::withMessages(['new_email' => $e->getMessage()]);
        }
    }
}
