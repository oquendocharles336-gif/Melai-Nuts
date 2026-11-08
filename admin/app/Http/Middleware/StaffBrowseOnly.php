<?php

namespace App\Http\Middleware;

use App\Services\Shop\CustomerSession;
use Closure;
use Illuminate\Http\Request;

/**
 * Staff, owners and admins may BROWSE the shop ("View shop" in the admin sidebar) with their admin
 * login, but never shop with it: cart, checkout, orders and points are for customer accounts.
 * Enforced here on the server, not only by hiding the buttons.
 */
class StaffBrowseOnly
{
    public const MESSAGE = 'You\'re viewing the shop as staff, so it\'s browse-only. Ordering needs a customer account.';

    public function __construct(private CustomerSession $customer) {}

    public function handle(Request $request, Closure $next)
    {
        if ($request->user() && ! $this->customer->check()) {
            if ($request->expectsJson() || ! $request->isMethod('GET')) {
                return response()->json(['message' => self::MESSAGE], 403);
            }

            return redirect()->route('shop.home')->with('shop_status', self::MESSAGE);
        }

        return $next($request);
    }
}
