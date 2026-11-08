<?php

namespace App\Http\Controllers\Shop;

use App\Http\Controllers\Controller;
use App\Services\Shop\CustomerSession;
use App\Services\Shop\ShopException;
use Illuminate\Http\Request;

/** Shared handling for the shop's controllers. */
abstract class ShopController extends Controller
{
    /**
     * A shop failure as the customer should see it: an ended sign-in goes back to the sign-in page,
     * anything else returns to the page with the message (JSON callers get it as `message`).
     */
    protected function failed(ShopException $e, Request $request, ?string $redirectTo = null)
    {
        if ($e->sessionEnded()) {
            app(CustomerSession::class)->forget();
            if ($request->expectsJson()) {
                return response()->json(['message' => $e->getMessage(), 'signed_out' => true], 401);
            }

            return redirect()->route('login')->with('error', $e->getMessage());
        }
        if ($request->expectsJson()) {
            return response()->json(['message' => $e->getMessage()], $e->reason === 'offline' || $e->reason === 'server' ? 503 : 422);
        }

        return ($redirectTo !== null ? redirect($redirectTo) : back())->withInput($request->except(['password', 'password_confirmation']))->with('shop_error', $e->getMessage());
    }
}
