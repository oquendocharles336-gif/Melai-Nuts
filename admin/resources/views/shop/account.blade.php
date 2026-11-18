@extends('layouts.shop')

@section('title', 'Your account')

@section('content')
    <h1 class="s-title">Hi, {{ explode(' ', $name)[0] }}</h1>

    <div class="s-layout">
        <section class="s-panel" aria-labelledby="me-title">
            <h2 id="me-title">Your details</h2>
            <div class="s-sum">
                <div><span>Name</span><b>{{ $name }}</b></div>
                <div><span>Email</span><span>{{ $email }}</span></div>
                <div><span>Mobile</span><span>{{ $phone !== '' ? $phone : 'Not set' }}</span></div>
            </div>
            <p class="s-note">This is your Melai Nuts app account: the same sign-in, cart, orders and points work in the app. To change your name or mobile number, use Account in the app.</p>

            {{-- Change email: a confirmation link goes to the NEW address; the current one gets a notice. --}}
            <details class="s-details" @if ($errors->has('new_email') || $errors->has('current_password')) open @endif>
                <summary class="s-link-btn">Change email</summary>
                <form method="POST" action="{{ route('shop.account.email') }}" class="s-form" novalidate data-busy="Sending…">@csrf
                    <div @class(['s-field', 'has-err' => $errors->has('new_email')])>
                        <label for="ce-email">New email</label>
                        <input id="ce-email" type="email" name="new_email" value="{{ old('new_email') }}" autocomplete="email" required maxlength="254">
                        @error('new_email')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    <div @class(['s-field', 'has-err' => $errors->has('current_password')])>
                        <label for="ce-password">Current password</label>
                        <input id="ce-password" type="password" name="current_password" autocomplete="current-password" required maxlength="128">
                        @error('current_password')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    <small class="s-note">We'll send a confirmation link to the new address. Your email changes only after you open it.</small>
                    <button class="s-btn primary">Send confirmation link</button>
                </form>
            </details>
        </section>

        <aside class="s-panel">
            <h2>Shortcuts</h2>
            <a href="{{ route('shop.orders') }}" class="s-btn ghost block"><x-icon name="receipt" :size="17" />My orders</a>
            <a href="{{ route('shop.points') }}" class="s-btn ghost block"><x-icon name="coins" :size="17" />Golden Kernel points</a>
            <form method="POST" action="{{ route('shop.logout') }}">@csrf
                <button class="s-btn ghost block"><x-icon name="logout" :size="17" />Sign out</button>
            </form>
        </aside>
    </div>
@endsection
