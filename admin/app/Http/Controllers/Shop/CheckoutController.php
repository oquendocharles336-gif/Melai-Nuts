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
            $quote = $this->orders->downpaymentQuote($cart['total']);
        } catch (ShopException $e) {
            return $this->failed($e, $request, route('shop.cart'));
        }

        return view('shop.checkout', [
            'cart' => $cart,
            'online' => $online,
            'quote' => $quote !== null && $quote['required'] ? $quote : null,
            'phone' => $this->customer->phone(),
        ]);
    }

    public function place(Request $request)
    {
        $needsPhone = trim($this->customer->phone()) === '';
        $data = $request->validate([
            'payment' => ['required', 'in:online,counter'],
            'notes' => ['nullable', 'string', 'max:'.Rules::NOTE_MAX],
            'phone' => $needsPhone ? Rules::phone(true) : ['nullable'],
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
            $payOnline = $data['payment'] === 'online';
            if ($payOnline && ! $this->orders->onlinePayment()['enabled']) {
                return back()->with('shop_error', $this->orders->onlinePayment()['message']);
            }
            $orderId = $this->orders->place($cart, $payOnline ? ShopOrders::PAY_ONLINE : ShopOrders::PAY_AT_COUNTER, trim((string) ($data['notes'] ?? '')));
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
}
