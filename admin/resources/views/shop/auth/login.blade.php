@extends('layouts.shop')

@section('title', 'Sign in')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            @include('partials.logo')
            <div>
                <h1>Welcome back</h1>
                <p class="s-sub">Sign in with your Melai Nuts app account.</p>
            </div>
            <form method="POST" action="{{ route('shop.login') }}" class="s-form" novalidate>
                @csrf
                <div class="s-field @error('email') has-err @enderror">
                    <label for="email">Email</label>
                    <input id="email" type="email" name="email" value="{{ old('email') }}" autocomplete="email" required autofocus maxlength="254">
                    @error('email')<span class="err">{{ $message }}</span>@enderror
                </div>
                <div class="s-field @error('password') has-err @enderror">
                    <label for="password">Password</label>
                    <div class="s-pw">
                        <input id="password" type="password" name="password" autocomplete="current-password" required maxlength="64">
                        <button type="button" data-show-pw="password" aria-pressed="false">Show</button>
                    </div>
                    @error('password')<span class="err">{{ $message }}</span>@enderror
                </div>
                <a href="{{ route('shop.forgot') }}" class="s-link-btn" style="justify-self:end">Forgot password?</a>
                <button type="submit" class="s-btn primary block">Sign in</button>
            </form>
            <p class="s-auth-foot">New to Melai Nuts? <a href="{{ route('shop.register') }}">Create an account</a></p>
        </div>
    </div>
@endsection
