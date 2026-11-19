{{--
    Cloudflare Turnstile inside a form: the widget adds the hidden field "cf-turnstile-response".
    The token is checked ONLY on the server (siteverify, single use): by this website before an
    account is created (App\Services\Auth\Turnstile) and by the Supabase Edge Functions.
    @include('shop.partials.turnstile', ['action' => 'sign_in' | 'send_code' | 'verify_email'])

    Rendered explicitly, and only once its form is visible: the sign-in panel is a <dialog> whose
    panels are hidden until opened, and a widget drawn while hidden can get stuck.
--}}
@php($siteKey = \App\Services\Auth\Turnstile::ready() ? \App\Services\Auth\Turnstile::siteKey() : '')
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
    <div @class(['s-field', 'has-err' => $errors->has('captcha')]) data-turnstile-field>
        <span class="hint">Security check</span>
        <div class="js-turnstile" data-sitekey="{{ $siteKey }}" data-action="{{ $action }}"></div>
        <span class="err" @if (! $errors->has('captcha')) hidden @endif>{{ $errors->first('captcha') }}</span>
        <noscript><span class="err">Please turn on JavaScript to complete the security check.</span></noscript>
    </div>
@else
    {{-- The detail (which variable is missing) is in the server log, never on the page. --}}
    <div class="s-flash note" role="note" data-turnstile-missing><x-icon name="alert" :size="18" /><span>The security check can't load right now, so this step can't be completed at the moment. Please try again later, or use the Melai Nuts app.</span></div>
@endif
