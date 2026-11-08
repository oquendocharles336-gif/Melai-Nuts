@extends('layouts.shop')

@section('title', 'Updated Terms')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            @include('partials.logo')
            <div>
                <h1>We've updated our Terms</h1>
                <p class="s-sub">Please read and accept the current Terms and Conditions and Privacy Policy to keep ordering.</p>
            </div>
            <form method="POST" action="{{ route('shop.terms') }}" class="s-form">
                @csrf
                <label class="s-check">
                    <input type="checkbox" name="terms" value="1" required>
                    <span>I agree to the <a href="{{ route('legal.terms') }}" target="_blank" rel="noopener">Terms and Conditions</a> and the <a href="{{ route('legal.privacy') }}" target="_blank" rel="noopener">Privacy Policy</a>.</span>
                </label>
                @error('terms')<span class="err" style="color:var(--bad)">{{ $message }}</span>@enderror
                <button type="submit" class="s-btn primary block">Continue</button>
            </form>
            <form method="POST" action="{{ route('shop.logout') }}" class="s-auth-foot">@csrf
                <button class="s-link-btn">Sign out instead</button>
            </form>
        </div>
    </div>
@endsection
