@extends('layouts.auth')
@section('title', 'Login · Melai Nuts Admin')
@section('heading1', 'Welcome')
@section('heading2', 'Back')
@section('blurb', 'Sign in with your Melai Nuts app account (the same email and password as in the app) to manage branches, stock, payments, refunds, and customer rewards.')
@section('form')
<form method="POST" action="{{ route('login') }}" novalidate x-cloak
      x-data="authForm({ mode: 'login', old: @js(['email' => old('email', '')]), errors: @js($errors->toArray()) })"
      @submit="onSubmit($event)">
    @csrf
    <h2 class="form-title">Login</h2>

    @if (session('status'))
        <div class="alert">{{ session('status') }}</div>
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

    <x-field name="email" label="Email" type="email" autocomplete="email" placeholder="admin@melainuts.com" />
    <x-field name="password" label="Password" password autocomplete="current-password" />

    <div class="row">
        <label><input type="checkbox" name="remember"> Remember me</label>
        <a href="{{ route('password.request') }}" class="link">Forgot password?</a>
    </div>

    <button type="submit" class="btn-primary" :disabled="submitting">
        <span x-text="submitting ? 'Logging in…' : 'Login'"></span>
    </button>
    <p class="switch">No account yet? <a href="{{ route('register') }}" class="link">Create Account</a></p>
</form>
@endsection
