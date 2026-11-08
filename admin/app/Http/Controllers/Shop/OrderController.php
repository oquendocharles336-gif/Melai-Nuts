<?php

namespace App\Http\Controllers\Shop;

use App\Services\Shop\ShopException;
use App\Services\Shop\ShopOrders;
use Illuminate\Http\Request;

/** My orders, one order, paying online (HitPay), the page HitPay returns to, and points. */
class OrderController extends ShopController
{
    public function __construct(private ShopOrders $orders) {}

    public function index(Request $request)
    {
        try {
            $orders = $this->orders->list();
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                return $this->failed($e, $request);
            }

            return view('shop.orders', ['orders' => [], 'error' => $e->getMessage()]);
        }

        return view('shop.orders', ['orders' => $orders, 'error' => null]);
    }

    public function show(Request $request, string $order)
    {
        try {
            $item = $this->orders->find($order);
        } catch (ShopException $e) {
            return $this->failed($e, $request, route('shop.orders'));
        }
        abort_if($item === null, 404);

        return view('shop.order', [
            'order' => $item,
            'placed' => $request->boolean('placed'),
            'checking' => $request->boolean('checking'),
        ]);
    }

    /** Polled by the order page while a payment is being confirmed. */
    public function status(Request $request, string $order)
    {
        try {
            $item = $this->orders->find($order);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }
        abort_if($item === null, 404);

        return response()->json([
            'status' => $item['status'],
            'status_label' => $item['status_label'],
            'payment_status' => $item['payment_status'],
            'downpayment_status' => $item['downpayment']['status'] ?? null,
            'can_pay' => $item['can_pay'],
        ]);
    }

    public function pay(Request $request, string $order)
    {
        try {
            $item = $this->orders->find($order);
            abort_if($item === null, 404);
            if (! $item['can_pay']) {
                return back()->with('shop_status', 'Nothing to pay online for this order.');
            }
            $url = $this->orders->startPayment($order);
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }
        session()->put('shop_paying_order', $order);

        return redirect()->away($url);
    }

    /**
     * HitPay sends the customer here after paying (HITPAY_WEB_REDIRECT_URL). Its query string is not
     * trusted for anything: only the HitPay webhook marks money as paid. This page just opens the
     * order and checks its status until the webhook has recorded the payment.
     */
    public function paymentReturn(Request $request)
    {
        $order = session()->pull('shop_paying_order');
        if (! is_string($order) || $order === '') {
            return redirect()->route('shop.orders')->with('shop_status', 'Thanks! Your latest order is below.');
        }

        return redirect()->route('shop.orders.show', ['order' => $order, 'checking' => 1]);
    }

    public function points(Request $request)
    {
        try {
            $points = $this->orders->points();
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                return $this->failed($e, $request);
            }

            return view('shop.points', ['points' => null, 'error' => $e->getMessage()]);
        }

        return view('shop.points', ['points' => $points, 'error' => null]);
    }
}
