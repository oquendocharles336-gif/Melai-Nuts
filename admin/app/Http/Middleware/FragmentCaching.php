<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Admin pages are served in two forms from the SAME URL: the full page (layout, stylesheets,
 * sidebar) and, for the in-page navigation in resources/js/ui.js (header X-Melai-Fragment: 1),
 * only the page content.
 *
 * Without telling the browser, it kept the content-only answer as THE copy of that URL. Back /
 * Forward then rebuilt the page from that copy: no <head>, no CSS, plain text. That is what
 * happened on /help, /settings, /admin/users and every other page that, unlike the four heavy
 * pages (ShellFirst), did not mark its fragment answers.
 *
 * So, on EVERY response of the site (global, in the web group):
 *  - fragment answers: Cache-Control: no-store (never written to the browser cache) and
 *    Vary: X-Melai-Fragment;
 *  - every other answer: Vary: X-Melai-Fragment, so a cache can never hand one form out for the other.
 */
class FragmentCaching
{
    public function handle(Request $request, Closure $next): Response
    {
        $response = $next($request);

        if ($request->header('X-Melai-Fragment') === '1') {
            $response->headers->set('Cache-Control', 'no-store, private');
        }
        // On every answer (error pages get their Content-Type only later, when sent): harmless on
        // JSON and downloads, and it means no answer can ever stand in for the other form.
        $response->setVary('X-Melai-Fragment', false);

        return $response;
    }
}
