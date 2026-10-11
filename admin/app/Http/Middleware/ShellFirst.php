<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Heavy pages (/dashboard, /orders, /s/inventory, /s/reports): answer at once with the layout and
 * skeleton placeholders, WITHOUT touching the database; the browser then fetches the page content
 * (same URL, header X-Melai-Fragment: 1) through the normal controller, with all its checks.
 *
 * Only for browsers that already ran this site's JavaScript (cookie melai_js=1, set by ui.js):
 * the first visit, clients without JavaScript, ?full=1 and the automated tests get the full
 * server-rendered page as before. Also skipped when a form just redirected here with messages.
 *
 * Fragment responses (from the shell or from in-page navigation) are never cached by the browser.
 */
class ShellFirst
{
    private const TITLES = ['dashboard' => 'Overview', 'orders.index' => 'Orders', 'inventory' => 'Stock', 'reports' => 'Reports'];

    public function handle(Request $request, Closure $next): Response
    {
        if ($request->header('X-Melai-Fragment') === '1') {
            $response = $next($request);
            $response->headers->set('Cache-Control', 'no-store, private');
            $response->headers->set('Vary', 'X-Melai-Fragment', false);

            return $response;
        }

        $name = $request->route()?->getName() === 'section' ? $request->route('slug') : $request->route()?->getName();
        $session = $request->hasSession() ? $request->session() : null;
        if ($request->isMethod('GET') && isset(self::TITLES[$name]) && $request->cookie('melai_js') === '1'
            && ! $request->expectsJson() && ! $request->boolean('full')
            && ! ($session && ($session->has('status') || $session->has('error') || $session->has('errors') || $session->has('_old_input')))) {
            return response()->view('shell', ['title' => self::TITLES[$name], 'kind' => $name])
                ->header('Cache-Control', 'no-store, private')->header('Vary', 'Cookie', false);
        }

        return $next($request);
    }
}
