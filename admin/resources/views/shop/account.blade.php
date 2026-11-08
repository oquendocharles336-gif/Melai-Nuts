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
            <p class="s-note">This is your Melai Nuts app account: the same sign-in, cart, orders and points work in the app. To change your details, use Account in the app.</p>
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
