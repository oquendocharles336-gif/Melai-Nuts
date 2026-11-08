@extends('layouts.card')
@section('title', 'Two-step sign-in')
@section('card')
<header class="s-dlg-head">
    @include('partials.logo')
    <h1>One more step</h1>
    <p>Two-step sign-in is on for this account. Enter the 6-digit code from your authenticator app, or one of your recovery codes.</p>
</header>
@error('code')
    <div class="s-flash bad" role="alert"><x-icon name="alert" :size="18" /><span>{{ $message }}</span></div>
@enderror
<form method="POST" action="{{ route('two-factor.verify') }}" class="s-form" data-busy="Checking…">
    @csrf
    <div @class(['s-field', 'has-err' => $errors->has('code')])>
        <label for="tf-code">Enter code</label>
        <input id="tf-code" type="text" name="code" autocomplete="one-time-code" inputmode="numeric" placeholder="123456" required maxlength="32" autofocus>
    </div>
    <button type="submit" class="s-btn primary block">Continue</button>
</form>
<form method="POST" action="{{ route('logout') }}" class="s-dlg-foot">
    @csrf
    <p><button type="submit" class="s-link-btn">Sign out instead</button></p>
</form>
@endsection
