@extends('layouts.auth')
@section('title', 'Sign in · Melai Nuts')
@section('heading1', 'Welcome')
@section('heading2', 'Back')
@section('blurb', 'One sign-in for everyone, with your Melai Nuts app account (the same email and password as in the app). Customers go to the shop; staff and owners go to the dashboard.')
@section('form')
<form method="POST" action="{{ route('login') }}" novalidate x-cloak
      x-data="authForm({ mode: 'login', old: @js(['email' => old('email', '')]), errors: @js($errors->toArray()) })"
      @submit="onSubmit($event)">
    @csrf
    <h2 class="form-title">Sign in</h2>

    @if (session('status'))
        <div class="alert">{{ session('status') }}</div>
    @endif
    @if (session('error'))
        <div class="alert" role="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">{{ session('error') }}</div>
    @endif
    @php $firebaseMissing = app(\App\Services\Firebase\FirebaseConfig::class)->missing(); @endphp
    @if ($firebaseMissing)
        <div class="alert" role="status" style="color:#8a5a00;background:#fff6e0;border-color:#f3d48a">
            Configuration missing: signing in with the Melai Nuts app account is not set up yet
            ({{ implode(', ', $firebaseMissing) }} empty in admin/.env). See INTEGRATION.md, section 2B.
        </div>
    @endif
    @error('auth')
        <div class="alert" role="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">{{ $message }}</div>
    @enderror

    <x-field name="email" label="Email" type="email" autocomplete="email" placeholder="you@example.com" />
    <x-field name="password" label="Password" password autocomplete="current-password" />

    <div class="row">
        <label><input type="checkbox" name="remember"> Remember me</label>
        <a href="{{ route('password.request') }}" class="link">Forgot password?</a>
    </div>

    <button type="submit" class="btn-primary" :disabled="submitting">
        <span x-text="submitting ? 'Signing in…' : 'Sign in'"></span>
    </button>
    <p class="switch">New to Melai Nuts? <a href="{{ route('shop.register') }}" class="link">Create an account</a></p>
    <p class="switch" style="margin-top:4px"><a href="{{ route('shop.home') }}" class="link">Browse the shop</a> · Staff without website access? <a href="{{ route('register') }}" class="link">Request access</a></p>
</form>
@endsection
