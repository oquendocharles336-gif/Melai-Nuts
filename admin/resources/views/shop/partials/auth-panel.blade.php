{{--
    The sign-in panel: the ONLY place to sign in (customers, staff, owners, admins), create an
    account, reset a password or ask for staff access. A modal on desktop, a full-screen sheet on
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
        AuthPanel::STAFF_ACCESS => 'Request staff access',
    ];
@endphp

<dialog class="s-dlg" id="auth-panel" data-auth-panel data-shown="{{ $shown }}" aria-labelledby="ap-{{ $shown }}-title" @if ($open) open data-start-open @endif>
    <div class="s-dlg-card">
        <a href="{{ route('shop.home') }}" class="s-dlg-close" data-panel-close aria-label="Close"><x-icon name="x" :size="20" /></a>

        @foreach ($titles as $panel => $title)
            <section class="s-dlg-sec" data-panel="{{ $panel }}" @if ($panel !== $shown) hidden @endif aria-labelledby="ap-{{ $panel }}-title">
                <header class="s-dlg-head">
                    @include('partials.logo')
                    <h2 id="ap-{{ $panel }}-title">{{ $title }}</h2>
                    <p>
                        @switch($panel)
                            @case(AuthPanel::SIGN_IN) One sign-in for the shop and the dashboard, with your Melai Nuts app email and password. @break
                            @case(AuthPanel::CREATE_ACCOUNT) One account for the website and the Melai Nuts app: same cart, orders and points. @break
                            @case(AuthPanel::RESET_PASSWORD) Enter your account's email and we'll send you a link to choose a new password. It works in the app too. @break
                            @case(AuthPanel::STAFF_ACCESS) For Melai Nuts staff. This creates your app account; an owner approves it and assigns your branch before you can use the dashboard. @break
                        @endswitch
                    </p>
                </header>

                @if ($panel === $shown)
                    @foreach ($messages as $tone => $text)
                        <div class="s-flash {{ $tone }}" role="{{ $tone === 'bad' ? 'alert' : 'status' }}"><x-icon :name="$tone === 'bad' ? 'alert' : 'check'" :size="18" /><span>{{ $text }}</span></div>
                    @endforeach
                @endif
                @if ($firebaseMissing && in_array($panel, [AuthPanel::SIGN_IN, AuthPanel::STAFF_ACCESS], true))
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
                            <button type="submit" class="s-btn primary block">Sign in</button>
                        </form>
                        <div class="s-dlg-foot">
                            <p>New to Melai Nuts? <a href="{{ AuthPanel::url(AuthPanel::CREATE_ACCOUNT) }}" data-panel-open="{{ AuthPanel::CREATE_ACCOUNT }}">Create an account</a></p>
                            <p>Staff without website access? <a href="{{ AuthPanel::url(AuthPanel::STAFF_ACCESS) }}" data-panel-open="{{ AuthPanel::STAFF_ACCESS }}">Request staff access</a></p>
                        </div>
                    @break

                    {{-- Create an account (customers; same rules as the app) ------------------------ --}}
                    @case(AuthPanel::CREATE_ACCOUNT)
                        <form method="POST" action="{{ route('shop.register') }}" class="s-form" novalidate data-busy="Creating your account…" data-live-validate>
                            @csrf
                            <input type="hidden" name="_panel" value="{{ $panel }}">
                            <div @class(['s-field', 'has-err' => $err($panel, 'name')])>
                                <label for="ca-name">Full name</label>
                                <input id="ca-name" type="text" name="name" value="{{ $val($panel, 'name') }}" autocomplete="name" required maxlength="{{ \App\Http\Requests\Rules::NAME_MAX }}">
                                @if ($e = $err($panel, 'name'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div class="s-two">
                                <div @class(['s-field', 'has-err' => $err($panel, 'email')])>
                                    <label for="ca-email">Email</label>
                                    <input id="ca-email" type="email" name="email" value="{{ $val($panel, 'email') }}" autocomplete="email" required maxlength="254">
                                    @if ($e = $err($panel, 'email'))<span class="err">{{ $e }}</span>@endif
                                </div>
                                <div @class(['s-field', 'has-err' => $err($panel, 'phone')])>
                                    <label for="ca-phone">Mobile number</label>
                                    <input id="ca-phone" type="tel" name="phone" value="{{ $val($panel, 'phone') }}" placeholder="09171234567" autocomplete="tel" inputmode="tel" required maxlength="16">
                                    @if ($e = $err($panel, 'phone'))<span class="err">{{ $e }}</span>@endif
                                </div>
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'password')])>
                                <label for="ca-password">Password</label>
                                <div class="s-pw">
                                    <input id="ca-password" type="password" name="password" autocomplete="new-password" required maxlength="64" aria-describedby="ca-pw-rules">
                                    <button type="button" data-show-pw="ca-password" aria-pressed="false">Show</button>
                                </div>
                                <ul class="s-rules" id="ca-pw-rules" data-pw-rules="ca-password">
                                    <li data-rule="length">8 to 64 characters</li>
                                    <li data-rule="upper">An uppercase letter</li>
                                    <li data-rule="digit">A number</li>
                                    <li data-rule="special">A symbol (!@#…)</li>
                                </ul>
                                @if ($e = $err($panel, 'password'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div class="s-field">
                                <label for="ca-password2">Confirm password</label>
                                <input id="ca-password2" type="password" name="password_confirmation" autocomplete="new-password" required maxlength="64">
                            </div>
                            <label @class(['s-check', 'has-err' => $err($panel, 'terms')])>
                                <input type="checkbox" name="terms" value="1" @checked($val($panel, 'terms')) required>
                                <span>I agree to the <a href="{{ route('legal.terms') }}" target="_blank" rel="noopener">Terms and Conditions</a> and the <a href="{{ route('legal.privacy') }}" target="_blank" rel="noopener">Privacy Policy</a>.</span>
                            </label>
                            @if ($e = $err($panel, 'terms'))<span class="s-err">{{ $e }}</span>@endif
                            <label class="s-check">
                                <input type="checkbox" name="order_updates" value="1" @checked($mine($panel) ? old('order_updates') : true)>
                                <span>Send me updates about my orders.</span>
                            </label>
                            <button type="submit" class="s-btn primary block">Create account</button>
                        </form>
                        <div class="s-dlg-foot">
                            <p>Already have an account? <a href="{{ AuthPanel::url(AuthPanel::SIGN_IN) }}" data-panel-open="{{ AuthPanel::SIGN_IN }}">Sign in</a></p>
                        </div>
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

                    {{-- Request staff access (the owner approves it) ----------------------------------- --}}
                    @case(AuthPanel::STAFF_ACCESS)
                        <form method="POST" action="{{ route('register') }}" class="s-form" novalidate data-busy="Sending request…" data-live-validate>
                            @csrf
                            <input type="hidden" name="_panel" value="{{ $panel }}">
                            <div @class(['s-field', 'has-err' => $err($panel, 'name')])>
                                <label for="sa-name">Full name</label>
                                <input id="sa-name" type="text" name="name" value="{{ $val($panel, 'name') }}" autocomplete="name" required maxlength="{{ \App\Http\Requests\Rules::NAME_MAX }}">
                                @if ($e = $err($panel, 'name'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'email')])>
                                <label for="sa-email">Email</label>
                                <input id="sa-email" type="email" name="email" value="{{ $val($panel, 'email') }}" autocomplete="email" required maxlength="254">
                                @if ($e = $err($panel, 'email'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'password')])>
                                <label for="sa-password">Password</label>
                                <div class="s-pw">
                                    <input id="sa-password" type="password" name="password" autocomplete="new-password" required maxlength="64" aria-describedby="sa-pw-rules">
                                    <button type="button" data-show-pw="sa-password" aria-pressed="false">Show</button>
                                </div>
                                <ul class="s-rules" id="sa-pw-rules" data-pw-rules="sa-password">
                                    <li data-rule="length">8 to 64 characters</li>
                                    <li data-rule="upper">An uppercase letter</li>
                                    <li data-rule="digit">A number</li>
                                    <li data-rule="special">A symbol (!@#…)</li>
                                </ul>
                                @if ($e = $err($panel, 'password'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            <div @class(['s-field', 'has-err' => $err($panel, 'password_confirmation')])>
                                <label for="sa-password2">Confirm password</label>
                                <input id="sa-password2" type="password" name="password_confirmation" autocomplete="new-password" required maxlength="64">
                                @if ($e = $err($panel, 'password_confirmation'))<span class="err">{{ $e }}</span>@endif
                            </div>
                            {{-- Consent is an active choice (never pre-ticked); the links open the full documents. --}}
                            <label @class(['s-check', 'has-err' => $err($panel, 'terms')])>
                                <input type="checkbox" name="terms" value="1" @checked($val($panel, 'terms'))>
                                <span>I have read and agree to the <a href="{{ route('legal.terms') }}" target="_blank" rel="noopener">Terms and Conditions</a> and the <a href="{{ route('legal.privacy') }}" target="_blank" rel="noopener">Privacy Policy</a>.</span>
                            </label>
                            @if ($e = $err($panel, 'terms'))<span class="s-err">{{ $e }}</span>@endif
                            <button type="submit" class="s-btn primary block">Request access</button>
                        </form>
                        <div class="s-dlg-foot">
                            <p>Already have an app account? <a href="{{ AuthPanel::url(AuthPanel::SIGN_IN) }}" data-panel-open="{{ AuthPanel::SIGN_IN }}">Sign in with it</a></p>
                        </div>
                    @break
                @endswitch
            </section>
        @endforeach
    </div>
</dialog>
