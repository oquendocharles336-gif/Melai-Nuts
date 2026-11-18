<?php

namespace App\Http\Controllers\Shop;

use App\Http\Requests\Rules;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Shop\CustomerSession;
use App\Services\Shop\ShopException;
use App\Services\Shop\SupabaseRest;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\Log;
use Illuminate\Validation\ValidationException;

/**
 * Verifies the signed-in customer's mobile number with an SMS code (Firebase phone
 * verification), so the shop can check out (migration 20261118040000).
 *
 *   1. GET  /shop/verify-phone   number + Google reCAPTCHA (Firebase's own phone-auth check)
 *   2. POST /shop/verify-phone   Firebase SMSes a code (accounts:sendVerificationCode)
 *   3. POST /shop/verify-phone/code   the code links the number to THIS Firebase account
 *      (accounts:signInWithPhoneNumber with the customer's ID token). The new ID token carries
 *      `phone_number`; claim_verified_phone() stores it (refused when another account has it).
 *
 * The number the database keeps is always the one in the Firebase token, never the typed one.
 */
class PhoneVerificationController extends ShopController
{
    private const PENDING = 'shop_phone_verification';

    public function __construct(
        private CustomerSession $customer,
        private FirebaseAuthClient $firebase,
        private SupabaseRest $rest,
    ) {}

    public function show(Request $request)
    {
        $pending = session(self::PENDING);
        $siteKey = null;
        $problem = null;
        try {
            $siteKey = $this->firebase->recaptchaSiteKey();
        } catch (FirebaseAuthException $e) {
            $problem = $e->getMessage();
        }

        return view('shop.auth.verify-phone', [
            'siteKey' => $siteKey,
            'problem' => $problem,
            'codeSent' => is_array($pending) && ($pending['uid'] ?? null) === $this->customer->uid(),
            'phone' => is_array($pending) ? (string) ($pending['phone'] ?? '') : '',
            'suggested' => $this->customer->phone(),
            'next' => $this->next($request),
        ]);
    }

    public function send(Request $request)
    {
        $data = $request->validate([
            'phone' => Rules::phone(true),
            'g-recaptcha-response' => ['required', 'string', 'max:4096'],
        ], ['g-recaptcha-response.required' => 'Please complete the security check.']);
        $phone = (string) Rules::normalizePhone($data['phone']);

        try {
            $session = $this->firebase->sendPhoneCode($phone, $data['g-recaptcha-response']);
        } catch (FirebaseAuthException $e) {
            throw ValidationException::withMessages(['phone' => $e->getMessage()]);
        }
        session()->put(self::PENDING, [
            'uid' => $this->customer->uid(),
            'phone' => $phone,
            'session_info' => Crypt::encryptString($session),
            'sent_at' => time(),
        ]);

        return redirect()->route('shop.phone', ['next' => $this->next($request)])
            ->with('shop_status', 'We sent a 6-digit code to '.$phone.'.');
    }

    public function confirm(Request $request)
    {
        $data = $request->validate(['code' => ['required', 'string', 'regex:/^\s*\d{6}\s*$/']],
            ['code.regex' => 'Please enter the 6-digit code from the SMS.']);
        $pending = session(self::PENDING);
        if (! is_array($pending) || ($pending['uid'] ?? null) !== $this->customer->uid()) {
            return redirect()->route('shop.phone')->with('shop_error', 'Please request a new code.');
        }

        try {
            $tokens = $this->firebase->linkPhoneNumber($this->customer->idToken(),
                Crypt::decryptString((string) $pending['session_info']), trim($data['code']));
            $this->customer->replaceTokens($tokens);
            $claimed = $this->rest->rpc('claim_verified_phone', [], $this->customer->idToken());
        } catch (FirebaseAuthException $e) {
            if ($e->reason === FirebaseAuthException::PHONE_TAKEN) {
                session()->forget(self::PENDING);
            }
            throw ValidationException::withMessages(['code' => $e->getMessage()]);
        } catch (ShopException $e) {
            return $this->failed($e, $request, route('shop.phone'));
        } catch (\Illuminate\Contracts\Encryption\DecryptException) {
            session()->forget(self::PENDING);

            return redirect()->route('shop.phone')->with('shop_error', 'Please request a new code.');
        }
        session()->forget(self::PENDING);
        $verified = is_array($claimed) ? (string) ($claimed['verified_phone'] ?? '') : '';
        if ($verified === '') {
            Log::warning('[shop] claim_verified_phone returned no number');

            return redirect()->route('shop.phone')->with('shop_error', 'We could not save your verified number. Please try again.');
        }
        $this->customer->rememberPhone($verified);

        return redirect($this->next($request))->with('shop_status', 'Your mobile number '.$verified.' is verified.');
    }

    public function restart()
    {
        session()->forget(self::PENDING);

        return redirect()->route('shop.phone');
    }

    /** Where to go afterwards: a page of this shop only (never an outside URL). */
    private function next(Request $request): string
    {
        $next = (string) $request->input('next', '');

        return $next !== '' && str_starts_with($next, '/') && ! str_starts_with($next, '//') ? $next : route('shop.checkout');
    }
}
