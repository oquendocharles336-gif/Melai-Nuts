@extends('layouts.shop')

@section('title', 'Create an account')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card" style="max-width:520px">
            @include('partials.logo')
            <div>
                <h1>Create your account</h1>
                <p class="s-sub">One account for the website and the Melai Nuts app: same cart, orders and points.</p>
            </div>
            <form method="POST" action="{{ route('shop.register') }}" class="s-form" novalidate>
                @csrf
                <div class="s-field @error('name') has-err @enderror">
                    <label for="name">Full name</label>
                    <input id="name" type="text" name="name" value="{{ old('name') }}" autocomplete="name" required maxlength="{{ \App\Http\Requests\Rules::NAME_MAX }}">
                    @error('name')<span class="err">{{ $message }}</span>@enderror
                </div>
                <div class="s-two">
                    <div class="s-field @error('email') has-err @enderror">
                        <label for="email">Email</label>
                        <input id="email" type="email" name="email" value="{{ old('email') }}" autocomplete="email" required maxlength="254">
                        @error('email')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    <div class="s-field @error('phone') has-err @enderror">
                        <label for="phone">Mobile number</label>
                        <input id="phone" type="tel" name="phone" value="{{ old('phone') }}" placeholder="09171234567" autocomplete="tel" inputmode="tel" required maxlength="16">
                        @error('phone')<span class="err">{{ $message }}</span>@enderror
                    </div>
                </div>
                <div class="s-field @error('password') has-err @enderror">
                    <label for="password">Password</label>
                    <div class="s-pw">
                        <input id="password" type="password" name="password" autocomplete="new-password" required maxlength="64" aria-describedby="pw-rules">
                        <button type="button" data-show-pw="password" aria-pressed="false">Show</button>
                    </div>
                    <ul class="s-rules" id="pw-rules" data-pw-rules="password">
                        <li data-rule="length">8 to 64 characters</li>
                        <li data-rule="upper">An uppercase letter</li>
                        <li data-rule="digit">A number</li>
                        <li data-rule="special">A symbol (!@#…)</li>
                    </ul>
                    @error('password')<span class="err">{{ $message }}</span>@enderror
                </div>
                <div class="s-field">
                    <label for="password_confirmation">Confirm password</label>
                    <input id="password_confirmation" type="password" name="password_confirmation" autocomplete="new-password" required maxlength="64">
                </div>
                <label class="s-check @error('terms') has-err @enderror">
                    <input type="checkbox" name="terms" value="1" @checked(old('terms')) required>
                    <span>I agree to the <a href="{{ route('legal.terms') }}" target="_blank" rel="noopener">Terms and Conditions</a> and the <a href="{{ route('legal.privacy') }}" target="_blank" rel="noopener">Privacy Policy</a>.</span>
                </label>
                @error('terms')<span class="err" style="color:var(--bad);font-size:12.5px;font-weight:600">{{ $message }}</span>@enderror
                <label class="s-check">
                    <input type="checkbox" name="order_updates" value="1" @checked(old('order_updates', true))>
                    <span>Send me updates about my orders.</span>
                </label>
                <button type="submit" class="s-btn primary block">Create account</button>
            </form>
            <p class="s-auth-foot">Already have an account? <a href="{{ route('login') }}">Sign in</a></p>
        </div>
    </div>
@endsection
