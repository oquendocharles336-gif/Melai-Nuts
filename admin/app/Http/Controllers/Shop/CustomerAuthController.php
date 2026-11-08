<?php

namespace App\Http\Controllers\Shop;

use App\Http\Middleware\EnsureCustomer;
use App\Http\Requests\Rules;
use App\Services\Shop\CustomerAccounts;
use App\Services\Shop\CustomerSession;
use App\Services\Shop\ShopCart;
use App\Services\Shop\ShopException;
use App\Support\AuthPanel;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;

/**
 * Customer sign-up, email check and password reset for the shop with the Melai Nuts app account
 * (Firebase). The forms live in the sign-in panel on the homepage (AuthPanel); the old addresses
 * open the matching panel. Nothing here ever signs anyone in to the admin website.
 */
class CustomerAuthController extends ShopController
{
    public function __construct(private CustomerAccounts $accounts, private CustomerSession $customer, private ShopCart $cart) {}

    /** Everyone signs in in the homepage's sign-in panel; old shop links open it. */
    public function showLogin()
    {
        if ($this->customer->check()) {
            return redirect()->route('shop.home');
        }

        return redirect()->to(AuthPanel::url(AuthPanel::SIGN_IN));
    }

    public function showRegister()
    {
        if ($this->customer->check()) {
            return redirect()->route('shop.home');
        }

        return redirect()->to(AuthPanel::url(AuthPanel::CREATE_ACCOUNT));
    }

    /** Same rules as the app's Create Account (name, PH mobile, password strength, Terms). */
    public function register(Request $request)
    {
        try {
            $data = $this->validateSignUp($request);
        } catch (ValidationException $e) {
            throw AuthPanel::back($e, AuthPanel::CREATE_ACCOUNT);
        }
        try {
            $this->accounts->startSignUp(trim($data['name']), $data['email'], $data['phone'], $data['password'], $request->boolean('order_updates'));
        } catch (ShopException $e) {
            return redirect()->to(AuthPanel::url(AuthPanel::CREATE_ACCOUNT))
                ->withInput($request->except(['password', 'password_confirmation']))->with('shop_error', $e->getMessage());
        }

        return redirect()->route('shop.verify');
    }

    private function validateSignUp(Request $request): array
    {
        return $request->validate([
            'name' => Rules::name(),
            'email' => Rules::email(),
            'phone' => Rules::phone(true),
            'password' => array_merge(Rules::newPassword($request->input('email'), $request->input('name')), ['confirmed']),
            'terms' => ['accepted'],
            'order_updates' => ['nullable', 'boolean'],
        ], [
            'terms.accepted' => 'Please agree to the Terms and Conditions and the Privacy Policy.',
            'password.confirmed' => 'The two passwords don\'t match.',
        ]);
    }

    public function showVerify()
    {
        $email = $this->accounts->pendingEmail();
        if ($email === null) {
            return $this->customer->check() ? redirect()->route('shop.home') : redirect()->to(AuthPanel::url(AuthPanel::CREATE_ACCOUNT));
        }

        return view('shop.auth.verify', ['email' => $email]);
    }

    public function checkVerified(Request $request)
    {
        try {
            $this->accounts->completeSignUp();
        } catch (ShopException $e) {
            return redirect()->route($e->sessionEnded() ? 'login' : 'shop.verify')->with('shop_error', $e->getMessage());
        }

        return $this->afterSignIn($request, 'Welcome to Melai Nuts, '.$this->customer->firstName().'! Your account is ready.');
    }

    public function resend()
    {
        try {
            $this->accounts->resendVerification();
        } catch (ShopException $e) {
            return redirect()->route($e->sessionEnded() ? 'login' : 'shop.verify')->with('shop_error', $e->getMessage());
        }

        return redirect()->route('shop.verify')->with('shop_status', 'We sent you a new verification link.');
    }

    public function cancelSignUp()
    {
        $this->accounts->cancelSignUp();

        return redirect()->route('shop.home');
    }

    public function showForgot()
    {
        return redirect()->to(AuthPanel::url(AuthPanel::RESET_PASSWORD));
    }

    public function forgot(Request $request)
    {
        try {
            $data = $request->validate(['email' => ['required', 'email', 'max:'.Rules::EMAIL_MAX]]);
        } catch (ValidationException $e) {
            throw AuthPanel::back($e, AuthPanel::RESET_PASSWORD);
        }
        try {
            $this->accounts->sendPasswordReset($data['email']);
        } catch (ShopException $e) {
            return redirect()->to(AuthPanel::url(AuthPanel::RESET_PASSWORD))->withInput()->with('shop_error', $e->getMessage());
        }

        return redirect()->to(AuthPanel::url(AuthPanel::SIGN_IN))->with('status', 'If that email has an account, we\'ve sent a link to reset your password.');
    }

    /** ONE logout for everything (same as the admin side's): every sign-in of this session ends. */
    public function logout(Request $request)
    {
        \Illuminate\Support\Facades\Auth::logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();

        return redirect()->route('shop.home')->with('shop_status', 'You\'re signed out.');
    }

    public function account()
    {
        return view('shop.account', [
            'name' => $this->customer->name(),
            'email' => $this->customer->email(),
            'phone' => $this->customer->phone(),
        ]);
    }

    public function showTerms()
    {
        return view('shop.auth.terms');
    }

    public function acceptTerms(Request $request)
    {
        $request->validate(['terms' => ['accepted']], ['terms.accepted' => 'Please agree to continue.']);
        try {
            $this->accounts->acceptTerms();
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }

        return redirect()->to((string) session()->pull(EnsureCustomer::INTENDED, route('shop.home')));
    }

    /** Bring the guest cart along, ask for updated Terms if needed, then go where they were headed. */
    public function afterSignIn(Request $request, string $welcome)
    {
        $note = null;
        try {
            $note = $this->cart->mergeGuestCart();
            $termsOk = $this->accounts->hasAcceptedCurrentTerms();
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                return $this->failed($e, $request);
            }
            $termsOk = true;
            $note = 'We couldn\'t add the items from before you signed in. They\'re still saved; please try again from your cart.';
        }
        if (! $termsOk) {
            return redirect()->route('shop.terms')->with('shop_status', $welcome);
        }
        $redirect = redirect()->to((string) session()->pull(EnsureCustomer::INTENDED, route('shop.home')))->with('shop_status', $welcome);

        return $note !== null ? $redirect->with('shop_note', $note) : $redirect;
    }
}
