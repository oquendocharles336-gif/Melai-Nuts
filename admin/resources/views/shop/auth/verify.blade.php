@extends('layouts.shop')

@section('title', 'Verify your email')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            <span class="s-empty-icon" style="width:64px;height:64px;border-radius:50%;display:grid;place-items:center;background:var(--brand-soft);color:var(--brand)"><x-icon name="check" :size="30" /></span>
            <div>
                <h1>Check your email</h1>
                @if ($codeSent)
                    <p class="s-sub">We sent a 6-digit code to <b>{{ $email }}</b>. Enter it below to finish creating your account. It expires in 10 minutes.</p>
                @else
                    <p class="s-sub">Complete the security check and we'll email a 6-digit code to <b>{{ $email }}</b>.</p>
                @endif
            </div>

            @if ($codeSent)
                <form method="POST" action="{{ route('shop.verify.check') }}" class="s-form" novalidate data-busy="Checking…">@csrf
                    <div @class(['s-field', 'has-err' => $errors->has('code')])>
                        <label for="vc-code">Verification code</label>
                        <input id="vc-code" type="text" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="\d{6}" maxlength="7" required placeholder="123456" style="letter-spacing:.3em;font-size:20px;text-align:center">
                        @error('code')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    @include('shop.partials.turnstile', ['action' => 'verify_email'])
                    <button class="s-btn primary block">Verify &amp; create account</button>
                </form>
            @endif

            {{-- Each form has its own security check: a token works for one request only. --}}
            <form method="POST" action="{{ route('shop.verify.resend') }}" class="s-form" novalidate data-busy="Sending…">@csrf
                @if ($codeSent)<p class="s-sub" style="margin:0">Didn't get it? Send a new code (one per minute).</p>@endif
                @include('shop.partials.turnstile', ['action' => 'send_code'])
                <button @class(['s-btn', 'block', 'primary' => ! $codeSent, 'ghost' => $codeSent])>{{ $codeSent ? 'Send a new code' : 'Email me the code' }}</button>
            </form>

            <p class="s-note">Can't find it? Check your spam or promotions folder. The email comes from Melai Nuts and has no link, only the code. We will never ask you for this code by phone or chat.</p>
            <form method="POST" action="{{ route('shop.verify.cancel') }}" class="s-auth-foot">@csrf
                <button class="s-link-btn">Cancel and go back to the shop</button>
            </form>
        </div>
    </div>
@endsection
