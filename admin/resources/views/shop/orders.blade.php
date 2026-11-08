@extends('layouts.shop')

@section('title', 'My orders')

@section('content')
    <div>
        <h1 class="s-title">My orders</h1>
        <p class="s-sub">Orders from the website and the Melai Nuts app, newest first.</p>
    </div>

    @if ($error)
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="alert" :size="28" /></span>
            <h3>We couldn't load your orders</h3>
            <p>{{ $error }}</p>
            <a href="{{ route('shop.orders') }}" class="s-btn primary">Try again</a>
        </div>
    @elseif ($orders === [])
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="receipt" :size="28" /></span>
            <h3>No orders yet</h3>
            <p>When you place an order here or in the app, it shows up on this page.</p>
            <a href="{{ route('shop.search') }}" class="s-btn primary">Start shopping</a>
        </div>
    @else
        <div class="s-orders">
            @foreach ($orders as $o)
                @include('shop.partials.order-row', ['o' => $o])
            @endforeach
        </div>
    @endif
@endsection
