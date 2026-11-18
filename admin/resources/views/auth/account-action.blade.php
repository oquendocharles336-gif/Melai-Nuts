@extends('layouts.shop')

@section('title', $state === 'reset' ? 'Choose a new password' : 'Melai Nuts account')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            @include('partials.logo')

            @if ($state === 'reset')
                <div>
                    <h1>Choose a new password</h1>
                    <p class="s-sub">For <b>{{ $email }}</b>. The new password works in the Melai Nuts app and on this website.</p>
                </div>
                <form method="POST" action="{{ route('account-action.reset') }}" class="s-form" novalidate data-busy="Saving…">@csrf
                    <input type="hidden" name="token" value="{{ $token }}">
                    <input type="text" name="username" value="{{ $email }}" autocomplete="username" hidden>
                    <div @class(['s-field', 'has-err' => $errors->has('password')])>
                        <label for="ra-password">New password</label>
                        <input id="ra-password" type="password" name="password" autocomplete="new-password" required maxlength="128">
                        @error('password')<span class="err">{{ $message }}</span>@enderror
                        <small>At least 8 characters, with an uppercase letter, a number and a symbol. Not your name or e-mail.</small>
                    </div>
                    <div class="s-field">
                        <label for="ra-password2">Confirm new password</label>
                        <input id="ra-password2" type="password" name="password_confirmation" autocomplete="new-password" required maxlength="128">
                    </div>
                    <button class="s-btn primary block">Save new password</button>
                </form>
            @elseif ($state === 'done')
                <div>
                    <h1>Password changed</h1>
                    <p class="s-sub">Sign in with your new password in the Melai Nuts app or on this website. This link no longer works, and any other sign-ins of <b>{{ $email }}</b> were ended.</p>
                </div>
                <a class="s-btn primary block" href="{{ $signIn }}">Sign in</a>
            @elseif ($state === 'confirm-email')
                <div>
                    <h1>Confirm your new email</h1>
                    <p class="s-sub">Your Melai Nuts account will use this address from now on. You'll sign in again in the app and on this website.</p>
                </div>
                <form method="POST" action="{{ route('account-action.confirm-email') }}" class="s-form" data-busy="Confirming…">@csrf
                    <input type="hidden" name="token" value="{{ $token }}">
                    <button class="s-btn primary block">Confirm new email</button>
                </form>
            @elseif ($state === 'cancel-email')
                <div>
                    <h1>Stop the email change?</h1>
                    <p class="s-sub">Your account keeps its current email. If you didn't ask for this change, change your password afterwards.</p>
                </div>
                <form method="POST" action="{{ route('account-action.cancel-email') }}" class="s-form" data-busy="Stopping…">@csrf
                    <input type="hidden" name="token" value="{{ $token }}">
                    <button class="s-btn primary block">Stop this change</button>
                </form>
            @elseif ($state === 'applied')
                <div>
                    <h1>{{ $title ?? 'Done' }}</h1>
                    <p class="s-sub">{{ $message }}</p>
                </div>
                <a class="s-btn primary block" href="{{ $signIn }}">{{ $signInLabel ?? 'Sign in' }}</a>
            @else
                <div>
                    <h1>This link does not work</h1>
                    <p class="s-sub">{{ $message }}</p>
                </div>
                @if ($reset ?? false)
                    <a class="s-btn primary block" href="{{ $forgot }}">Request a new reset link</a>
                @endif
            @endif
        </div>
    </div>
@endsection
