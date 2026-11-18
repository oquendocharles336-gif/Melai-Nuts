{{--
    Cloudflare Turnstile inside a form: the widget adds the hidden field "cf-turnstile-response".
    The token is checked ONLY on the server (Supabase Edge Functions, siteverify, single use).
    @include('shop.partials.turnstile', ['action' => 'sign_in' | 'send_code' | 'verify_email'])

    Rendered explicitly, and only once its form is visible: the sign-in panel is a <dialog> whose
    panels are hidden until opened, and a widget drawn while hidden can get stuck.
--}}
@php($siteKey = (string) config('melai.captcha.turnstile_site_key'))
@if ($siteKey !== '')
    @once
        <script>
            (() => {
                const scan = () => {
                    if (!window.turnstile) return;
                    document.querySelectorAll('.js-turnstile:not([data-rendered])').forEach((el) => {
                        if (el.offsetParent === null) return;   // not visible yet
                        el.dataset.rendered = '1';
                        window.turnstile.render(el, {
                            sitekey: el.dataset.sitekey, action: el.dataset.action,
                            theme: 'light', 'refresh-expired': 'auto',
                        });
                    });
                };
                window.melaiTurnstileReady = () => {
                    scan();
                    new MutationObserver(scan).observe(document.body, { attributes: true, subtree: true, attributeFilter: ['open', 'hidden', 'class'] });
                };
            })();
        </script>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=melaiTurnstileReady" async defer></script>
    @endonce
    <div class="s-field">
        <span class="hint">Security check</span>
        <div class="js-turnstile" data-sitekey="{{ $siteKey }}" data-action="{{ $action }}"></div>
        <noscript><span class="err">Please turn on JavaScript to complete the security check.</span></noscript>
    </div>
@else
    <div class="s-flash note" role="note"><x-icon name="alert" :size="18" /><span>The security check is not set up yet (TURNSTILE_SITE_KEY is empty), so this step can't be completed right now.</span></div>
@endif
