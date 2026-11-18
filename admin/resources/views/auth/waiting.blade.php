@extends('layouts.card')
@section('title', 'Waiting for admin access')
@section('card')
<header class="s-dlg-head">
    @include('partials.logo')
    <h1>Waiting for admin access</h1>
</header>
@if (session('status'))<div class="s-flash ok" role="status"><x-icon name="check" :size="18" /><span>{{ session('status') }}</span></div>@endif
@if (session('error'))<div class="s-flash bad" role="alert"><x-icon name="alert" :size="18" /><span>{{ session('error') }}</span></div>@endif

<div class="s-card-copy">
    @if ($user->usesFirebase())
        <p>Your Melai Nuts app account <strong>{{ $user->email }}</strong> exists. Before you can use the dashboard:</p>
        <ol>
            <li>@if ($user->firebase_email_verified) <strong>Email verified.</strong>
                @else <strong>Verify your email:</strong> complete the security check below to get a 6-digit code at {{ $user->email }} (check spam), then enter it here. @endif</li>
            <li><strong>Your owner account must be linked</strong> to the app's owner registry. Staff do not use the website: they sign in to the Melai Nuts app.</li>
        </ol>
        @if ($state && ! in_array($state['state'], ['linked', 'profile_missing'], true))
            <p class="s-note">{{ \App\Services\Auth\LinkState::describe($state['state'])[0] }}: {{ $state['message'] }}</p>
        @endif
    @else
        <p>Your account <strong>{{ $user->email }}</strong> was created. An administrator needs to give you access before you can use the dashboard.</p>
    @endif
</div>

<div class="s-card-actions">
    <a class="s-btn primary" href="{{ route('waiting') }}">Check again</a>
    <form method="POST" action="{{ route('logout') }}">@csrf<button class="s-btn ghost" type="submit">Sign out</button></form>
</div>

@if ($user->usesFirebase() && ! $user->firebase_email_verified)
    <div class="s-card-copy">
        @if (session('waiting_code_sent'))
            <form method="POST" action="{{ route('waiting.verify-email.code') }}" class="s-form" novalidate>@csrf
                <div @class(['s-field', 'has-err' => $errors->has('code')])>
                    <label for="wv-code">6-digit code</label>
                    <input id="wv-code" type="text" name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="7" required placeholder="123456">
                    @error('code')<span class="err">{{ $message }}</span>@enderror
                </div>
                @include('shop.partials.turnstile', ['action' => 'verify_email'])
                <button class="s-btn primary" type="submit">Verify email</button>
            </form>
        @endif
        <form method="POST" action="{{ route('waiting.verify-email') }}" class="s-form" novalidate>@csrf
            @include('shop.partials.turnstile', ['action' => 'send_code'])
            <button class="s-btn ghost" type="submit">{{ session('waiting_code_sent') ? 'Send a new code' : 'Email me a verification code' }}</button>
        </form>
    </div>
@endif
@endsection
