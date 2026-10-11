<?php

namespace App\Http\Middleware;

use App\Services\AdminActions;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * After every successful change (any non-GET request in the signed-in area that did not fail),
 * bump the global data version so no cached page, JSON answer or badge from before the change
 * is served to anyone (App\Support\Swr). POST routes that only READ are listed in READ_ONLY.
 */
class BumpCacheVersion
{
    private const READ_ONLY = ['logout', 'waiting.verify-email', 'cards.tap', 'cards.find', 'reports.forecast.save'];

    public function handle(Request $request, Closure $next): Response
    {
        $response = $next($request);

        if (! $request->isMethodSafe() && $response->getStatusCode() < 400
            && ! in_array($request->route()?->getName(), self::READ_ONLY, true)
            && ! ($request->hasSession() && ($request->session()->has('errors') || $request->session()->has('error')))) {
            AdminActions::bump();
        }

        return $response;
    }
}
