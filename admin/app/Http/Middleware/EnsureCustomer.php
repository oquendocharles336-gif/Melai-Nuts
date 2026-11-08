<?php

namespace App\Http\Middleware;

use App\Services\Shop\CustomerSession;
use Closure;
use Illuminate\Http\Request;

/**
 * Shop pages that need a signed-in customer (checkout, orders, points, account). Others are sent
 * to the shop sign-in and come straight back afterwards.
 */
class EnsureCustomer
{
    public const INTENDED = 'shop_intended';

    public function __construct(private CustomerSession $customer) {}

    public function handle(Request $request, Closure $next)
    {
        if (! $this->customer->check()) {
            if ($request->expectsJson()) {
                return response()->json(['message' => 'Please sign in to continue.'], 401);
            }
            if ($request->isMethod('GET')) {
                $request->session()->put(self::INTENDED, $request->fullUrl());
            }

            return redirect()->route('shop.login')->with('shop_status', 'Please sign in or create an account to continue.');
        }

        return $next($request);
    }
}
