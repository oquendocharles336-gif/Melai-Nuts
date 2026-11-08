@extends('layouts.shop')

@section('title', 'Reset your password')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            @include('partials.logo')
            <div>
                <h1>Reset your password</h1>
                <p class="s-sub">Enter your account's email and we'll send you a link to choose a new password. It works for the app too.</p>
            </div>
            <form method="POST" action="{{ route('shop.forgot') }}" class="s-form" novalidate>
                @csrf
                <div class="s-field @error('email') has-err @enderror">
                    <label for="email">Email</label>
                    <input id="email" type="email" name="email" value="{{ old('email') }}" autocomplete="email" required maxlength="254">
                    @error('email')<span class="err">{{ $message }}</span>@enderror
                </div>
                <button type="submit" class="s-btn primary block">Send reset link</button>
            </form>
            <p class="s-auth-foot"><a href="{{ route('shop.login') }}">Back to sign in</a></p>
        </div>
    </div>
@endsection
