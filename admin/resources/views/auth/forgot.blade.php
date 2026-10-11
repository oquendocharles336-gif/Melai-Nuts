@extends('layouts.base')
@section('content')
<main class="center-page"><div class="card">
    <h1>Forgot your password?</h1>
    <p>Website logins use your Melai Nuts app account. Enter its email and Firebase will send a reset link; the new password works in the app and on this website.</p>
    @if (session('status')) <p class="alert">{{ session('status') }}</p> @endif
    @if (session('error')) <p class="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">{{ session('error') }}</p> @endif
    @error('email') <p class="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">{{ $message }}</p> @enderror
    <form method="POST" action="{{ route('password.email') }}">
        @csrf
        <div class="field"><label for="email">App email</label>
            <input class="light-input" id="email" type="email" name="email" value="{{ old('email') }}" required maxlength="255" autocomplete="email"></div>
        <div class="btn-row">
            <button class="btn-solid" type="submit">Send reset link</button>
            <a class="btn-outline" href="{{ route('login') }}">Back to login</a>
        </div>
    </form>
    <p class="muted">Older website-only logins (no app account) are reset by an administrator.</p>
</div></main>
@endsection
