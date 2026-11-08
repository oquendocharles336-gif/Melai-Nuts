<?php

namespace App\Http\Controllers\Shop;

use App\Http\Middleware\EnsureCustomer;
use App\Http\Requests\Rules;
use App\Services\Shop\CustomerAccounts;
use App\Services\Shop\CustomerSession;
use App\Services\Shop\ShopCart;
use App\Services\Shop\ShopException;
use Illuminate\Http\Request;

/**
 * Customer sign-in / sign-up for the shop with the Melai Nuts app account (Firebase).
 * Staff, owners and riders are refused here (they have their own sign-in), and nothing here ever
 * signs anyone in to the admin website.
 */
class CustomerAuthController extends ShopController
{
    public function __construct(private CustomerAccounts $accounts, private CustomerSession $customer, private ShopCart $cart) {}

    public function showLogin()
    {
        if ($this->customer->check()) {
            return redirect()->route('shop.home');
        }

        return view('shop.auth.login');
    }

    public function login(Request $request)
    {
        $data = $request->validate([
            'email' => ['required', 'email', 'max:'.Rules::EMAIL_MAX],
            'password' => ['required', 'string', 'max:'.Rules::PASSWORD_MAX],
        ]);
        try {
            if ($this->accounts->signIn($data['email'], $data['password']) === 'verify') {
                return redirect()->route('shop.verify')->with('shop_status', 'Please verify your email first. We\'ve sent you a new link.');
            }
        } catch (ShopException $e) {
            return back()->withInput($request->only('email'))->with('shop_error', $e->getMessage());
        }

        return $this->afterSignIn($request, 'Welcome back, '.$this->customer->firstName().'!');
    }

    public function showRegister()
    {
        if ($this->customer->check()) {
            return redirect()->route('shop.home');
        }

        return view('shop.auth.register');
    }

    /** Same rules as the app's Create Account (name, PH mobile, password strength, Terms). */
    public function register(Request $request)
    {
        $data = $request->validate([
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
        try {
            $this->accounts->startSignUp(trim($data['name']), $data['email'], $data['phone'], $data['password'], $request->boolean('order_updates'));
        } catch (ShopException $e) {
            return back()->withInput($request->except(['password', 'password_confirmation']))->with('shop_error', $e->getMessage());
        }

        return redirect()->route('shop.verify');
    }

    public function showVerify()
    {
        $email = $this->accounts->pendingEmail();
        if ($email === null) {
            return redirect()->route($this->customer->check() ? 'shop.home' : 'shop.register');
        }

        return view('shop.auth.verify', ['email' => $email]);
    }

    public function checkVerified(Request $request)
    {
        try {
            $this->accounts->completeSignUp();
        } catch (ShopException $e) {
            return redirect()->route($e->sessionEnded() ? 'shop.login' : 'shop.verify')->with('shop_error', $e->getMessage());
        }

        return $this->afterSignIn($request, 'Welcome to Melai Nuts, '.$this->customer->firstName().'! Your account is ready.');
    }

    public function resend()
    {
        try {
            $this->accounts->resendVerification();
        } catch (ShopException $e) {
            return redirect()->route($e->sessionEnded() ? 'shop.login' : 'shop.verify')->with('shop_error', $e->getMessage());
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
        return view('shop.auth.forgot');
    }

    public function forgot(Request $request)
    {
        $data = $request->validate(['email' => ['required', 'email', 'max:'.Rules::EMAIL_MAX]]);
        try {
            $this->accounts->sendPasswordReset($data['email']);
        } catch (ShopException $e) {
            return back()->withInput()->with('shop_error', $e->getMessage());
        }

        return redirect()->route('shop.login')->with('shop_status', 'If that email has an account, we\'ve sent a link to reset your password.');
    }

    public function logout(Request $request)
    {
        $this->customer->forget();
        $request->session()->forget([ShopCart::GUEST, 'shop_cart_count', 'shop_branch', 'shop_paying_order', EnsureCustomer::INTENDED]);
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
    private function afterSignIn(Request $request, string $welcome)
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
