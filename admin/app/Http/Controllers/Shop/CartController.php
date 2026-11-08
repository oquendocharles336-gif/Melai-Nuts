<?php

namespace App\Http\Controllers\Shop;

use App\Services\Shop\ShopCart;
use App\Services\Shop\ShopException;
use Illuminate\Http\Request;

class CartController extends ShopController
{
    public function __construct(private ShopCart $cart) {}

    public function show(Request $request)
    {
        try {
            $cart = $this->cart->view();
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                return $this->failed($e, $request);
            }

            return view('shop.cart', ['cart' => null, 'error' => $e->getMessage()]);
        }

        return view('shop.cart', ['cart' => $cart, 'error' => null]);
    }

    public function add(Request $request)
    {
        $data = $request->validate([
            'product' => ['required', 'string', 'max:64'],
            'variant' => ['required', 'string', 'max:64'],
            'qty' => ['nullable', 'integer', 'min:1', 'max:'.ShopCart::MAX_QTY],
        ]);
        try {
            $wanted = (int) ($data['qty'] ?? 1);
            $added = $this->cart->add($data['product'], $data['variant'], $wanted);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }
        $message = $added < $wanted ? "Only $added more available. Added $added to your cart." : 'Added to your cart.';
        if ($request->expectsJson()) {
            return response()->json(['message' => $message, 'added' => $added, 'count' => $this->cart->count()]);
        }

        return back()->with('shop_status', $message);
    }

    public function update(Request $request, string $variant)
    {
        $data = $request->validate([
            'product' => ['required', 'string', 'max:64'],
            'qty' => ['required', 'integer', 'min:0', 'max:'.ShopCart::MAX_QTY],
        ]);
        try {
            $this->cart->update($data['product'], $variant, (int) $data['qty']);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }
        if ($request->expectsJson()) {
            return response()->json(['count' => $this->cart->count()]);
        }

        return back()->with('shop_status', (int) $data['qty'] === 0 ? 'Removed from your cart.' : 'Cart updated.');
    }

    public function voucher(Request $request)
    {
        $data = $request->validate(['code' => ['required', 'string', 'max:30', 'regex:/^[A-Za-z0-9-]+$/']], [
            'code.regex' => 'Voucher codes use letters, numbers and dashes only.',
        ]);
        try {
            $this->cart->applyVoucher($data['code']);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }

        return back()->with('shop_status', 'Voucher applied.');
    }

    public function removeVoucher(Request $request)
    {
        try {
            $this->cart->removeVoucher();
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }

        return back()->with('shop_status', 'Voucher removed.');
    }

    public function points(Request $request)
    {
        $on = $request->boolean('on');
        try {
            $this->cart->redeemPoints($on);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }

        return back()->with('shop_status', $on ? 'Points applied to this order.' : 'Points no longer applied.');
    }
}
