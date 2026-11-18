<?php

namespace Tests\Feature;

use Tests\TestCase;

/** Phase 5 hardening: security headers, secure session cookie, no third-party scripts. */
class SecurityHeadersTest extends TestCase
{
    public function test_every_page_sends_the_security_headers(): void
    {
        $r = $this->get('/?panel=sign-in')->assertOk();   // the sign-in panel's page
        $r->assertHeader('X-Content-Type-Options', 'nosniff');
        $r->assertHeader('X-Frame-Options', 'DENY');
        $r->assertHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
        $csp = $r->headers->get('Content-Security-Policy');
        $this->assertStringContainsString("default-src 'self'", $csp);
        $this->assertStringContainsString("frame-ancestors 'none'", $csp);
        $this->assertStringContainsString("object-src 'none'", $csp);
        $this->assertStringNotContainsString('jsdelivr', $csp, 'no CDN may serve scripts');
        $this->assertStringContainsString('serial=(self)', $r->headers->get('Permissions-Policy'));
    }

    public function test_hsts_only_over_https(): void
    {
        $this->get('/login')->assertHeaderMissing('Strict-Transport-Security');
        $this->get('https://localhost/login')->assertHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    }

    public function test_session_cookie_is_secure_by_default_in_production(): void
    {
        $read = function (string $env, ?string $flag): mixed {
            $set = function (string $k, ?string $v): void {
                if ($v === null) {
                    putenv($k);
                    unset($_ENV[$k], $_SERVER[$k]);
                } else {
                    putenv("$k=$v");
                    $_ENV[$k] = $_SERVER[$k] = $v;
                }
            };
            $set('APP_ENV', $env);
            $set('SESSION_SECURE_COOKIE', $flag);
            try {
                return (require base_path('config/session.php'))['secure'];
            } finally {
                $set('APP_ENV', 'testing');
                $set('SESSION_SECURE_COOKIE', null);
            }
        };
        $this->assertTrue($read('production', null));
        $this->assertFalse($read('local', null));
        $this->assertFalse((bool) $read('production', 'false'), 'an explicit setting still wins');
    }

    public function test_no_page_template_loads_scripts_from_another_site(): void
    {
        // The one exception: Cloudflare Turnstile's api.js (the security check of sign-up, of
        // sign-in after repeated failures and of the app's /captcha page). Cloudflare does not
        // allow self-hosting it; the CSP allows only that origin (SecurityHeaders::TURNSTILE).
        // And Google reCAPTCHA's api.js on the shop's "Verify mobile number" page: Firebase phone
        // verification on the web only accepts a reCAPTCHA token (SecurityHeaders::RECAPTCHA).
        $allowed = '#^https://(challenges\.cloudflare\.com/turnstile/v0/api\.js|www\.google\.com/recaptcha/api\.js)(\?|$)#';
        $offenders = [];
        foreach (new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator(resource_path('views'))) as $f) {
            if (! $f->isFile()) {
                continue;
            }
            preg_match_all('/<script[^>]+src=["\'](https?:[^"\']+)/i', file_get_contents($f->getPathname()), $m);
            foreach ($m[1] as $src) {
                if (! preg_match($allowed, $src)) {
                    $offenders[] = $f->getPathname().' '.$src;
                }
            }
        }
        $this->assertSame([], $offenders);
    }
}
