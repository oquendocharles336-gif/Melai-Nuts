{{--
    The sign-in panel: the ONLY place to sign in on the website (customers and the owner), create a
    customer account or reset a password. Staff sign in to the app only. A modal on desktop, a full-screen sheet on
    phones. It opens from the header's "Sign in" button, or already open from /?panel=<name>
    (App\Support\AuthPanel), e.g. after /login or a "please sign in" redirect.

    Every form sends `_panel`, so after a failed submit the same panel opens with its errors and the
    typed values (never passwords). Without JavaScript it still works: links reload the homepage
    with another panel open.
--}}
@use('App\Support\AuthPanel')
@php
    $shown = $open ?? AuthPanel::SIGN_IN;                     // the visible panel
    $mine = fn (string $p) => $open === $p;                    // errors / typed values belong to the open panel only
    $val = fn (string $p, string $k, $d = '') => $mine($p) ? old($k, $d) : $d;
    $err = fn (string $p, string $k) => $mine($p) ? $errors->first($k) : null;
    $firebaseMissing = app(\App\Services\Firebase\FirebaseConfig::class)->missing();
    $messages = $open ? array_filter([
        'ok' => session('status'),
        'bad' => session('error') ?? session('shop_error') ?? $errors->first('auth'),
    ]) : [];
    $titles = [
        AuthPanel::SIGN_IN => 'Welcome back',
        AuthPanel::CREATE_ACCOUNT => 'Create your account',
        AuthPanel::RESET_PASSWORD => 'Reset your password',
    ];
@endphp

<dialog class="s-dlg" id="auth-panel" data-auth-panel data-shown="{{ $shown }}" aria-labelledby="ap-{{ $shown }}-title" @if ($open) open data-start-open @endif>
    <div class="s-dlg-card">
        <a href="{{ route('shop.home') }}" class="s-dlg-close" data-panel-close aria-label="Close"><x-icon name="x" :size="20" /></a>

        @foreach ($titles as $panel => $title)
            <section class="s-dlg-sec" data-panel="{{ $panel }}" @if ($panel !== $shown) hidden @endif aria-labelledby="ap-{{ $panel }}-title">
                @if ($panel === AuthPanel::CREATE_ACCOUNT)
                    {{-- Same look as the app's "Create your account" screen: warm gradient hero with the
                         mascot, then the form on a rounded sheet that slides up over it. --}}
                    <header class="ca-hero">
                        <a href="{{ AuthPanel::url(AuthPanel::SIGN_IN) }}" class="ca-back" data-panel-open="{{ AuthPanel::SIGN_IN }}" aria-label="Back to sign in"><x-icon name="arrow-left" :size="22" :stroke="2.2" /></a>
                        <span class="ca-mascot"><img src="{{ asset('images/melai-logo.svg') }}" width="112" height="112" alt="" decoding="async"></span>
                        <h2 id="ap-{{ $panel }}-title">{{ $title }}</h2>
                        <span class="ca-ornament" aria-hidden="true"><span></span><i></i><span></span></span>
                        <p>Order online, track your orders and earn Golden Kernel loyalty points.</p>
                    </header>
                @else
                <header class="s-dlg-head">
                    @include('partials.logo')
                    <h2 id="ap-{{ $panel }}-title">{{ $title }}</h2>
                    <p>
                        @switch($panel)
                            @case(AuthPanel::SIGN_IN) Sign in with your Melai Nuts email and password. @break
                            @case(AuthPanel::RESET_PASSWORD) Enter your account's email and we'll send you a link to choose a new password. It works in the app too. @break
                        @endswitch
                    </p>
                </header>
                @endif
                @if ($panel === AuthPanel::CREATE_ACCOUNT)<div class="ca-sheet">@endif

                @if ($panel === $shown)
                    @foreach ($messages as $tone => $text)
                        <div class="s-flash {{ $tone }}" role="{{ $tone === 'bad' ? 'alert' : 'status' }}"><x-icon :name="$tone === 'bad' ? 'alert' : 'check'" :size="18" /><span>{{ $text }}</span></div>
                    @endforeach
                @endif
                @if ($firebaseMissing && $panel === AuthPanel::SIGN_IN)
                    <div class="s-flash note" role="status"><x-icon name="alert" :size="18" />
                        <span>Configuration missing: signing in with the Melai Nuts app account is not set up yet ({{ implode(', ', $firebaseMissing) }} empty in admin/.env). See INTEGRATION.md, section 2B.</span></div>
                @endif

                @switch($panel)
                    {{-- Sign in ----------------------------------------------------------------- --}}
                    @case(AuthPanel::SIGN_IN)
                        <form method="POST" action="{{ route('login') }}" class="s-form" novalidate data-busy="Signing in…">
                            @csrf
                            <input type="hidden" name="_panel" value="{{ $panel }}">
                            <div @class(['s-field', 'has-err' => $err($panel, 'email')])>
                                <label for="si-email">Email</label>
                                <input id="si-email" type="email" name="email" value="{{ $val($panel, 'email') }}" autocomplete="username" required maxlength="254" placeholder="you@example.com">
                                @if ($e = $err($panel, 'email'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'password')])>
                                <label for="si-password">Password</label>
                                <div class="s-pw">
                                    <input id="si-password" type="password" name="password" autocomplete="current-password" required>
                                    <button type="button" data-show-pw="si-password" aria-pressed="false">Show</button>
                                </div>
                                @if ($e = $err($panel, 'password'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div class="s-dlg-row">
                                <label class="s-check"><input type="checkbox" name="remember" value="1" @checked($val($panel, 'remember'))><span>Remember me</span></label>
                                <a href="{{ AuthPanel::url(AuthPanel::RESET_PASSWORD) }}" data-panel-open="{{ AuthPanel::RESET_PASSWORD }}">Forgot password?</a>
                            </div>
                            {{-- After 15 sign-in attempts (this email or this network, 30 minutes) the
                                 server asks for a security check. A gate, never a lockout. --}}
                            @if (session('auth_captcha_required'))
                                @include('shop.partials.turnstile', ['action' => 'sign_in'])
                            @endif
                            <button type="submit" class="s-btn primary block">Sign in</button>
                        </form>
                        <div class="s-dlg-foot">
                            <p>New to Melai Nuts? <a href="{{ AuthPanel::url(AuthPanel::CREATE_ACCOUNT) }}" data-panel-open="{{ AuthPanel::CREATE_ACCOUNT }}">Create an account</a></p>
                            <p>Melai Nuts staff sign in to the Melai Nuts app, not on this website.</p>
                        </div>
                    @break

                    {{-- Create an account (customers; same rules as the app) ------------------------ --}}
                    @case(AuthPanel::CREATE_ACCOUNT)
                        <form method="POST" action="{{ route('shop.register') }}" class="s-form ca-form" novalidate data-busy="Creating your account…" data-live-validate data-signup>
                            @csrf
                            <input type="hidden" name="_panel" value="{{ $panel }}">

                            {{-- About you: first and last name (like the app's PersonNameFields) and the mobile number. --}}
                            <p class="ca-group" id="ca-about">About you</p>
                            <div @class(['s-field', 'has-err' => $err($panel, 'first_name')])>
                                <label for="ca-first-name">First Name</label>
                                <input id="ca-first-name" type="text" name="first_name" value="{{ $val($panel, 'first_name') }}" placeholder="Juan" autocomplete="given-name" autocapitalize="words" required maxlength="{{ \App\Http\Requests\Rules::NAME_PART_MAX }}">
                                @if ($e = $err($panel, 'first_name'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'last_name')])>
                                <label for="ca-last-name">Last Name</label>
                                <input id="ca-last-name" type="text" name="last_name" value="{{ $val($panel, 'last_name') }}" placeholder="Dela Cruz" autocomplete="family-name" autocapitalize="words" required maxlength="{{ \App\Http\Requests\Rules::NAME_PART_MAX }}">
                                @if ($e = $err($panel, 'last_name'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'phone')])>
                                <label for="ca-phone">Mobile Number</label>
                                <input id="ca-phone" type="tel" name="phone" value="{{ $val($panel, 'phone') }}" placeholder="09171234567" autocomplete="tel-national" inputmode="numeric" required maxlength="11" aria-describedby="ca-phone-hint">
                                <span class="hint" id="ca-phone-hint">11 digits. Used for order updates.</span>
                                @if ($e = $err($panel, 'phone'))<span class="err">{{ $e }}</span>@endif
                            </div>

                            {{-- Sign-in details: email and password, with the live strength check. --}}
                            <p class="ca-group">Sign-in details</p>
                            <div @class(['s-field', 'has-err' => $err($panel, 'email')])>
                                <label for="ca-email">Email Address</label>
                                <input id="ca-email" type="email" name="email" value="{{ $val($panel, 'email') }}" placeholder="you@example.com" autocomplete="email" required maxlength="254" aria-describedby="ca-email-hint">
                                <span class="hint" id="ca-email-hint">Used to sign in and to verify your account.</span>
                                @if ($e = $err($panel, 'email'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'password')])>
                                <label for="ca-password">Password</label>
                                <div class="s-pw">
                                    <input id="ca-password" type="password" name="password" placeholder="Create a password" autocomplete="new-password" required maxlength="64" aria-describedby="ca-pw-rules">
                                    <button type="button" class="s-pw-eye" data-show-pw="ca-password" aria-pressed="false" aria-label="Show password">
                                        <x-icon name="eye" :size="22" class="when-hidden" /><x-icon name="eye-off" :size="22" class="when-shown" />
                                    </button>
                                </div>
                                @if ($e = $err($panel, 'password'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            {{-- Password Strength Check: ticks as each rule is met; the badge counts them (shop.js). --}}
                            <div class="ca-strength" id="ca-pw-rules" data-pw-rules="ca-password" data-level="0">
                                <div class="ca-strength-head">
                                    <b>Password Strength Check</b>
                                    <span class="ca-badge" data-pw-badge aria-live="polite">Weak (0/4)</span>
                                </div>
                                <ul>
                                    <li data-rule="length">At least 8 characters</li>
                                    <li data-rule="upper">At least 1 uppercase letter (A-Z)</li>
                                    <li data-rule="digit">At least 1 number (0-9)</li>
                                    <li data-rule="special">At least 1 special character (!@#$_)</li>
                                </ul>
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'password_confirmation')])>
                                <label for="ca-password2">Confirm Password</label>
                                <div class="s-pw">
                                    <input id="ca-password2" type="password" name="password_confirmation" placeholder="Type your password again" autocomplete="new-password" required maxlength="64">
                                    <button type="button" class="s-pw-eye" data-show-pw="ca-password2" aria-pressed="false" aria-label="Show password">
                                        <x-icon name="eye" :size="22" class="when-hidden" /><x-icon name="eye-off" :size="22" class="when-shown" />
                                    </button>
                                </div>
                                @if ($e = $err($panel, 'password_confirmation'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <label @class(['s-check', 'has-err' => $err($panel, 'terms')])>
                                <input type="checkbox" name="terms" value="1" @checked($val($panel, 'terms')) required>
                                <span>I agree to the <a href="{{ route('legal.terms') }}" target="_blank" rel="noopener" data-legal-doc="Terms and Conditions">Terms and Conditions</a> and the <a href="{{ route('legal.privacy') }}" target="_blank" rel="noopener" data-legal-doc="Privacy Policy">Privacy Policy</a>.
                                    {{-- Filled in by shop.js: the box stays locked until both links were opened. --}}
                                    <small class="s-check-hint" data-terms-hint hidden></small></span>
                            </label>
                            @if ($e = $err($panel, 'terms'))<span class="s-err">{{ $e }}</span>@endif
                            <label class="s-check">
                                <input type="checkbox" name="order_updates" value="1" @checked($mine($panel) ? old('order_updates') : true)>
                                <span>Send me updates about my orders.</span>
                            </label>
                            {{-- Checked by this server before the account is created, then we email a 6-digit code. --}}
                            @include('shop.partials.turnstile', ['action' => 'send_code'])
                            <button type="submit" class="s-btn primary block">Create account</button>
                        </form>
                        <div class="s-dlg-foot">
                            <p>Already have an account? <a href="{{ AuthPanel::url(AuthPanel::SIGN_IN) }}" data-panel-open="{{ AuthPanel::SIGN_IN }}">Sign in</a></p>
                        </div>
                        </div>{{-- .ca-sheet --}}
                    @break

                    {{-- Reset password --------------------------------------------------------------- --}}
                    @case(AuthPanel::RESET_PASSWORD)
                        <form method="POST" action="{{ route('shop.forgot') }}" class="s-form" novalidate data-busy="Sending…">
                            @csrf
                            <input type="hidden" name="_panel" value="{{ $panel }}">
                            <div @class(['s-field', 'has-err' => $err($panel, 'email')])>
                                <label for="rp-email">Email</label>
                                <input id="rp-email" type="email" name="email" value="{{ $val($panel, 'email') }}" autocomplete="email" required maxlength="254">
                                @if ($e = $err($panel, 'email'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <button type="submit" class="s-btn primary block">Send reset link</button>
                        </form>
                        <div class="s-dlg-foot">
                            <p><a href="{{ AuthPanel::url(AuthPanel::SIGN_IN) }}" data-panel-open="{{ AuthPanel::SIGN_IN }}">Back to sign in</a></p>
                        </div>
                    @break

                @endswitch
            </section>
        @endforeach
    </div>
</dialog>
