@extends('layouts.shop')

@section('content')
    <section class="s-hero" aria-labelledby="hero-title">
        <span class="eyebrow">Melai Nuts · Laguna</span>
        <h1 id="hero-title">Fresh-roasted nuts, ready when you are.</h1>
        <p>Order online, then pick up at your nearest Melai Nuts branch. Same account, cart and points as the Melai Nuts app.</p>
        <div class="s-hero-actions">
            <a href="{{ route('shop.search') }}" class="s-btn s-btn-honey">Shop all nuts <x-icon name="arrow-right" :size="16" /></a>
            @unless ($shopCustomer ?? null)
                <a href="{{ route('shop.register') }}" class="s-btn s-btn-glass">Create an account</a>
            @endunless
        </div>
        <div class="s-perks">
            <span><x-icon name="store" :size="15" /> Store pickup</span>
            <span><x-icon name="coins" :size="15" /> Earn Golden Kernel points</span>
            <span><x-icon name="wallet" :size="15" /> GCash, QR Ph, card or cash</span>
        </div>
    </section>

    @if ($error)
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="alert" :size="28" /></span>
            <h3>We couldn't load the shop</h3>
            <p>{{ $error }}</p>
            <a href="{{ route('shop.home') }}" class="s-btn primary">Try again</a>
        </div>
    @else
        @if ($categories)
            <section class="s-section" aria-labelledby="cat-title">
                <div class="s-section-head"><h2 id="cat-title">Browse by category</h2></div>
                <div class="s-chips">
                    <a href="{{ route('shop.search') }}" class="s-chip is-on">All nuts</a>
                    @foreach ($categories as $c)
                        <a href="{{ route('shop.search', ['category' => $c['id']]) }}" class="s-chip">{{ $c['name'] }} <small>{{ $c['product_count'] }}</small></a>
                    @endforeach
                </div>
            </section>
        @endif

        @if ($featured)
            <section class="s-section" aria-labelledby="feat-title">
                <div class="s-section-head">
                    <h2 id="feat-title">Featured for you</h2>
                </div>
                <div class="s-grid">
                    @foreach ($featured as $p)
                        @include('shop.partials.card', ['p' => $p, 'branch' => $branch])
                    @endforeach
                </div>
            </section>
        @endif

        <section class="s-section" aria-labelledby="pop-title">
            <div class="s-section-head">
                <h2 id="pop-title">Popular {{ $branch ? 'at '.$branch['name'] : 'right now' }}</h2>
                <a href="{{ route('shop.search') }}">See all <x-icon name="arrow-right" :size="16" /></a>
            </div>
            @if ($popular)
                <div class="s-grid">
                    @foreach ($popular as $p)
                        @include('shop.partials.card', ['p' => $p, 'branch' => $branch])
                    @endforeach
                </div>
            @else
                <div class="s-empty">
                    <span class="s-empty-icon"><x-icon name="leaf" :size="28" /></span>
                    <h3>No products yet</h3>
                    <p>New batches are on the way. Please check back soon.</p>
                </div>
            @endif
        </section>
    @endif
@endsection
