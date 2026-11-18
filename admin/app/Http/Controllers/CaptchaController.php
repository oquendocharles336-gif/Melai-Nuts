<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

/**
 * GET /captcha?action=sign_in|send_code|verify_email — the page the Melai Nuts app shows in a
 * WebView for Cloudflare Turnstile (CAPTCHA_PAGE_URL in the app's dart-defines). Public, no
 * session needed; it only renders the widget with the public site key. Tokens are verified by
 * the Supabase Edge Functions, never here.
 */
class CaptchaController extends Controller
{
    private const ACTIONS = ['sign_in', 'send_code', 'verify_email'];

    public function show(Request $request)
    {
        $action = (string) $request->query('action', '');

        return response()->view('captcha.app', [
            'siteKey' => (string) config('melai.captcha.turnstile_site_key'),
            'action' => in_array($action, self::ACTIONS, true) ? $action : 'sign_in',
        ])->header('Cache-Control', 'no-store');
    }
}
