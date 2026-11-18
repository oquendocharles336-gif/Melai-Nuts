@extends('layouts.shop')

@section('title', 'Verify your mobile number')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            <span class="s-empty-icon" style="width:64px;height:64px;border-radius:50%;display:grid;place-items:center;background:var(--brand-soft);color:var(--brand)"><x-icon name="check" :size="30" /></span>
            <div>
                <h1>Verify your mobile number</h1>
                @if ($codeSent)
                    <p class="s-sub">We sent a 6-digit code by SMS to <b>{{ $phone }}</b>. Enter it below.</p>
                @else
                    <p class="s-sub">A verified mobile number is needed to place orders. It is the number our staff use to reach you about your order. We'll text you a 6-digit code.</p>
                @endif
            </div>

            @if ($codeSent)
                <form method="POST" action="{{ route('shop.phone.confirm') }}" class="s-form" novalidate data-busy="Checking…">@csrf
                    <input type="hidden" name="next" value="{{ $next }}">
                    <div @class(['s-field', 'has-err' => $errors->has('code')])>
                        <label for="vp-code">6-digit code</label>
                        <input id="vp-code" type="text" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="\d{6}" maxlength="7" required placeholder="123456" style="letter-spacing:.3em;font-size:20px;text-align:center">
                        @error('code')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    <button class="s-btn primary block">Verify number</button>
                </form>
                <form method="POST" action="{{ route('shop.phone.restart') }}" class="s-auth-foot">@csrf
                    <button class="s-link-btn">Use a different number or send a new code</button>
                </form>
            @elseif ($problem !== null)
                <p class="s-note">{{ $problem }}</p>
            @else
                <form method="POST" action="{{ route('shop.phone.send') }}" class="s-form" novalidate data-busy="Sending…">@csrf
                    <input type="hidden" name="next" value="{{ $next }}">
                    <div @class(['s-field', 'has-err' => $errors->has('phone')])>
                        <label for="vp-phone">Mobile number</label>
                        <input id="vp-phone" type="tel" name="phone" inputmode="tel" autocomplete="tel-national" maxlength="20" required placeholder="0917 123 4567" value="{{ old('phone', $suggested) }}">
                        @error('phone')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    {{-- Firebase checks this reCAPTCHA before it sends an SMS (abuse protection). --}}
                    <div class="g-recaptcha" data-sitekey="{{ $siteKey }}"></div>
                    @error('g-recaptcha-response')<span class="err">{{ $message }}</span>@enderror
                    <button class="s-btn primary block">Text me the code</button>
                </form>
                <script src="https://www.google.com/recaptcha/api.js" async defer></script>
            @endif

            <p class="s-note">Standard SMS rates from your network may apply. We will never ask you for this code by phone or chat.</p>
        </div>
    </div>
@endsection
