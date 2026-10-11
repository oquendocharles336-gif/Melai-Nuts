@extends('layouts.panel')
@section('title', 'Two-step sign-in · Melai Nuts Admin')
@section('page-title', 'Two-step sign-in')
@section('page-sub', 'Optional. After your password, the website also asks for a code from an authenticator app on your phone.')
@section('panel')
@include('partials.flash')
<x-card :title="$enabled ? 'On' : ($pendingSecret ? 'Finish turning it on' : 'Off')" :subtitle="$enabled ? $remaining.' recovery code(s) left' : 'Works with Google Authenticator, Microsoft Authenticator, Aegis, 1Password and others'">
@if ($enabled)
    @if ($recoveryCodes)
        <p><b>Recovery codes</b> (each works once if you lose your phone; keep them somewhere safe):</p>
        <pre style="font-size:1rem;line-height:1.6">{{ implode("\n", $recoveryCodes) }}</pre>
    @endif
    <form method="POST" action="{{ route('two-factor.disable') }}" style="max-width:24rem">
        @csrf @method('DELETE')
        <div class="field"><label for="current_password">Password</label>
            <input class="light-input" id="current_password" type="password" name="current_password" autocomplete="current-password" required>
            @error('current_password')<p class="note" style="color:var(--bad)">{{ $message }}</p>@enderror</div>
        <div class="field"><label for="code">Code from your authenticator (or a recovery code)</label>
            <input class="light-input" id="code" name="code" autocomplete="one-time-code" inputmode="numeric" required>
            @error('code')<p class="note" style="color:var(--bad)">{{ $message }}</p>@enderror</div>
        <button class="btn" type="submit">Turn off</button>
    </form>
@elseif ($pendingSecret)
    <p>1. In your authenticator app choose <b>Add account → Enter a setup key</b> and type this key (time-based):</p>
    <pre style="font-size:1.1rem;letter-spacing:.08em">{{ trim(chunk_split($pendingSecret, 4, ' ')) }}</pre>
    <p class="note">Or open this link on the phone that has the app: <a href="{{ $otpauth }}">{{ $otpauth }}</a></p>
    <form method="POST" action="{{ route('two-factor.confirm') }}" style="max-width:24rem">
        @csrf
        <div class="field"><label for="code">2. Enter the 6-digit code the app shows</label>
            <input class="light-input" id="code" name="code" autocomplete="one-time-code" inputmode="numeric" required>
            @error('code')<p class="note" style="color:var(--bad)">{{ $message }}</p>@enderror</div>
        <button class="btn-solid" type="submit">Turn on</button>
    </form>
@else
    <form method="POST" action="{{ route('two-factor.start') }}" style="max-width:24rem">
        @csrf
        <div class="field"><label for="current_password">Your password (to start)</label>
            <input class="light-input" id="current_password" type="password" name="current_password" autocomplete="current-password" required>
            @error('current_password')<p class="note" style="color:var(--bad)">{{ $message }}</p>@enderror</div>
        <button class="btn-solid" type="submit">Set up two-step sign-in</button>
    </form>
@endif
</x-card>
@endsection
