<?php

namespace App\Http\Controllers\Shop;

use App\Http\Requests\Rules;
use App\Services\Shop\CustomerSession;
use App\Services\Shop\ShopCart;
use App\Services\Shop\ShopCatalog;
use App\Services\Shop\ShopException;
use App\Services\Shop\ShopOrders;
use App\Services\Shop\SupabaseRest;
use Illuminate\Http\Request;

/**
 * Cart -> checkout -> confirmation. Store pickup only (same as the app): the order goes to the
 * customer's automatic branch, and the server decides any downpayment (place_order).
 */
class CheckoutController extends ShopController
{
    public function __construct(
        private ShopCart $cart,
        private ShopOrders $orders,
        private ShopCatalog $catalog,
        private CustomerSession $customer,
        private SupabaseRest $rest,
    ) {}

    public function show(Request $request)
    {
        try {
            $cart = $this->cart->view();
            if ($cart['lines'] === []) {
                return redirect()->route('shop.cart')->with('shop_status', 'Your cart is empty.');
            }
            if ($cart['branch'] === null) {
                return redirect()->route('shop.cart')->with('shop_error', 'Choose your pickup branch first: allow location, and we\'ll pick the nearest one.');
            }
            $online = $this->orders->onlinePayment();
            // First order (50% or 100% online first): decided by the server for this cart.
            $first = $this->orders->firstOrderQuote($cart);
            $quote = $first !== null && ! $first['first_order'] ? $this->orders->downpaymentQuote($cart['total']) : null;
            $pinRequired = $this->usesPoints($cart) && $this->orders->loyaltyPinRequired();
        } catch (ShopException $e) {
            return $this->failed($e, $request, route('shop.cart'));
        }

        return view('shop.checkout', [
            'cart' => $cart,
            'online' => $online,
            'quote' => $quote !== null && $quote['required'] ? $quote : null,
            // Online first, every order (migration 20261119080000; place_order decides again):
            // with online payment switched off no order with something to pay is taken, and
            // without a downpayment there is no cash order.
            'paused' => $online['read'] && ! $online['enabled'] && $cart['total'] > 0,
            'cashUnavailable' => $quote !== null && ! $quote['required'] && $cart['total'] > 0,
            // null = could not be loaded (the page offers a retry and does not let the order go).
            'first' => $first,
            'phone' => $this->customer->phone(),
            // Points on this order and a loyalty PIN set: the PIN field is shown (the database checks it).
            'pinRequired' => $pinRequired,
        ]);
    }

    public function place(Request $request)
    {
        $needsPhone = trim($this->customer->phone()) === '';
        $data = $request->validate([
            // half / full = the first-order choice (paid online); the server checks it is allowed.
            'payment' => ['required', 'in:online,counter,half,full'],
            'notes' => Rules::orderNotes(),
            'phone' => $needsPhone ? Rules::phone(true) : ['nullable'],
            'loyalty_pin' => ['nullable', 'string', 'max:6'],
        ]);

        try {
            if ($needsPhone) {
                $phone = (string) Rules::normalizePhone($data['phone']);
                $this->rest->update('customer_profiles', ['firebase_uid' => 'eq.'.$this->customer->uid()], ['phone' => $phone], $this->customer->idToken());
                $this->customer->rememberPhone($phone);
            }
            $cart = $this->cart->view();
            if ($cart['lines'] === [] || $cart['cart_id'] === null) {
                return redirect()->route('shop.cart')->with('shop_error', 'Your cart is empty.');
            }
            // Points on this order from a customer who set a loyalty PIN: the PIN first
            // (the database refuses the points without it, migration 20261120020000).
            if ($this->usesPoints($cart) && $this->orders->loyaltyPinRequired()) {
                $pin = trim((string) ($data['loyalty_pin'] ?? ''));
                if (! preg_match('/^\d{4,6}$/', $pin)) {
                    return back()->withInput()->withErrors(['loyalty_pin' => 'Enter your 4 to 6 digit loyalty PIN to use your points.']);
                }
                if (($problem = $this->orders->verifyLoyaltyPin($pin)) !== null) {
                    return back()->withInput()->withErrors(['loyalty_pin' => $problem]);
                }
            }
            $firstChoice = in_array($data['payment'], ['half', 'full'], true) ? $data['payment'] : null;
            $payOnline = $data['payment'] === 'online' || $firstChoice !== null;
            if ($payOnline && ! $this->orders->onlinePayment()['enabled']) {
                return back()->with('shop_error', $this->orders->onlinePayment()['message']);
            }
            $orderId = $this->orders->place($cart, $payOnline ? ShopOrders::PAY_ONLINE : ShopOrders::PAY_AT_COUNTER,
                trim((string) ($data['notes'] ?? '')), $firstChoice);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }

        $this->cart->placed();
        $this->catalog->forgetStock($cart['branch']['id'] ?? null);

        // Online order, or a pickup order waiting for its downpayment: straight to HitPay. If the
        // payment page can't open, the order page offers "Pay now"; the order is never lost.
        try {
            $order = $this->orders->find($orderId);
            if ($order !== null && $order['can_pay']) {
                session()->put('shop_paying_order', $orderId);

                return redirect()->away($this->orders->startPayment($orderId));
            }
        } catch (ShopException $e) {
            return redirect()->route('shop.orders.show', ['order' => $orderId, 'placed' => 1])
                ->with('shop_error', $e->getMessage().' Your order is saved: use "Pay now" below.');
        }

        return redirect()->route('shop.orders.show', ['order' => $orderId, 'placed' => 1]);
    }

    private function usesPoints(array $cart): bool
    {
        return ($cart['redeem_points'] ?? false) && (int) ($cart['points_used'] ?? 0) > 0;
    }
}
