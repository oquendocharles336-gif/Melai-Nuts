<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Vite;
use Symfony\Component\HttpFoundation\Response;

/**
 * Security headers on every response (config/melai.php 'security').
 *
 * CSP: scripts, styles, images, workers and fetches only from this site, plus Google Fonts.
 * 'unsafe-inline' / 'unsafe-eval' are still needed by the page scripts and Alpine.js
 * (moving them to files + Alpine's CSP build is the next hardening step); everything else
 * (other script origins, framing, plugins, form posts elsewhere) is blocked.
 * OCR (Tesseract.js) is self-hosted under /vendor/tesseract, so no CDN is allowed.
 */
class SecurityHeaders
{
    public function handle(Request $request, Closure $next): Response
    {
        $response = $next($request);
        $h = $response->headers;

        $h->set('X-Content-Type-Options', 'nosniff');
        $h->set('X-Frame-Options', 'DENY');
        $h->set('Referrer-Policy', 'strict-origin-when-cross-origin');
        $h->set('Cross-Origin-Opener-Policy', 'same-origin');
        // Web Serial is used by the RFID card reader page; nothing else needs device access.
        $h->set('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(self)');

        if (config('melai.security.hsts') && $request->isSecure()) {
            $h->set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
        }
        if (config('melai.security.csp') && ! Vite::isRunningHot() && ! $h->has('Content-Security-Policy')) {
            $h->set('Content-Security-Policy', self::csp());
        }

        return $response;
    }

    public static function csp(): string
    {
        return implode('; ', [
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
            "font-src 'self' https://fonts.gstatic.com",
            "img-src 'self' data: blob:",
            "connect-src 'self' blob: data:",
            "worker-src 'self' blob:",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'self'",
            "frame-ancestors 'none'",
        ]);
    }
}
