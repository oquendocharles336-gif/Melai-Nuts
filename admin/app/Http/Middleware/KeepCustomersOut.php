<?php

namespace App\Http\Middleware;

use App\Services\Shop\CustomerSession;
use Closure;
use Illuminate\Http\Request;

/**
 * In front of EVERY admin route (pages and JSON endpoints), before `auth`.
 *
 * A shop customer is never logged in on the admin `web` guard (the shop has its own separate
 * session, CustomerSession), so `auth` would already refuse them. This makes the refusal explicit
 * and friendly, on the server:
 *   - pages: back to the shop with "You don't have access to that page."
 *   - JSON / API calls (and any non-GET request): 403, nothing is read or changed.
 *
 * A staff member who is also signed in to the shop with their own customer account still reaches
 * the admin side through their admin login (the `web` guard), exactly as before.
 */
class KeepCustomersOut
{
    public const MESSAGE = 'You don\'t have access to that page. It\'s for Melai Nuts staff only.';

    public function __construct(private CustomerSession $customer) {}

    public function handle(Request $request, Closure $next)
    {
        if ($this->customer->check() && ! $request->user()) {
            if ($request->expectsJson() || str_ends_with($request->path(), '.json') || ! $request->isMethod('GET')) {
                return response()->json(['message' => self::MESSAGE], 403);
            }

            return redirect()->route('shop.home')->with('shop_error', self::MESSAGE);
        }

        return $next($request);
    }
}
