@extends('layouts.shop')

@section('main-class', 's-home')

@section('content')
    @php
        $kinds = collect($popular)->pluck('art')->filter()->unique()->values();
        $heroArt = collect(['gift', 'chili', 'cashew'])->map(fn ($k, $n) => $kinds->contains($k) ? $k : ($kinds[$n] ?? $k))->all();
        $best = $popular[0] ?? null;
    @endphp

    {{-- 1. Hero ------------------------------------------------------------------------------ --}}
    <section class="s-hero" aria-labelledby="hero-title">
        <div class="s-hero-copy">
            <span class="s-eyebrow">Fresh-roasted in Laguna</span>
            <h1 id="hero-title">Small-batch nuts, <em>roasted</em> the slow way.</h1>
            <p class="s-hero-lead">Garlic peanuts, buttery cashews and pasalubong boxes from our Laguna kitchen. Order online, then pick them up at your nearest Melai Nuts branch.</p>
            <div class="s-hero-actions">
                <a href="#best" class="s-btn primary">Shop best sellers <x-icon name="arrow-right" :size="17" class="ico-arrow" /></a>
                <a href="#how" class="s-btn ghost">How pickup works</a>
            </div>
            <div class="s-proof">
                <span><x-icon name="store" :size="17" /> Store pickup</span>
                <span><x-icon name="coins" :size="17" /> Earn Golden Kernel points</span>
                <span><x-icon name="wallet" :size="17" /> GCash, QR Ph, card or cash</span>
            </div>
        </div>
        <div class="s-hero-art" aria-hidden="true">
            <div class="ring"></div>
            <div class="plate"></div>
            <div class="piece p1">@include('shop.partials.art', ['kind' => $heroArt[0]])</div>
            <div class="piece p2">@include('shop.partials.art', ['kind' => $heroArt[1]])</div>
            <div class="piece p3">@include('shop.partials.art', ['kind' => $heroArt[2]])</div>
            @if ($branch)
                <div class="tag"><span>Pick up today at</span><b>{{ $branch['name'] }}</b><span>{{ $branch['hours'] ?: '' }}</span></div>
            @elseif ($shopBranches)
                <div class="tag"><span>Pick up at</span><b>{{ count($shopBranches) }} {{ \Illuminate\Support\Str::plural('branch', count($shopBranches)) }}</b><span>across Laguna</span></div>
            @endif
            @if ($best)
                <div class="tag left"><span>Best seller</span><b>{{ $best['name'] }}</b></div>
            @endif
        </div>
    </section>

    @if ($error)
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="alert" :size="30" /></span>
            <h3>We couldn't load the shop</h3>
            <p>{{ $error }}</p>
            <a href="{{ route('shop.home') }}" class="s-btn primary">Try again</a>
        </div>
    @else
        {{-- 2. Categories ------------------------------------------------------------------------ --}}
        @if ($categories)
            <section class="s-section" aria-labelledby="cat-title">
                <div class="s-section-head" data-reveal>
                    <div><span class="s-eyebrow">Browse</span><h2 id="cat-title">Find your favourite</h2></div>
                </div>
                <div class="s-tiles">
                    @foreach ($categories as $n => $c)
                        <a href="{{ route('shop.search', ['category' => $c['id']]) }}" class="s-tile" data-reveal style="--d: {{ $n * 0.07 }}s; --tile: {{ \App\Services\Shop\ShopCatalog::tintFor($c['art']) }}">
                            @include('shop.partials.art', ['kind' => $c['art'], 'label' => $c['name']])
                            <span class="s-tile-text"><b>{{ $c['name'] }}</b><span>{{ $c['product_count'] }} {{ \Illuminate\Support\Str::plural('product', $c['product_count']) }}</span></span>
                        </a>
                    @endforeach
                    <a href="{{ route('shop.search') }}" class="s-tile all" data-reveal style="--d: {{ count($categories) * 0.07 }}s">
                        <span class="all-mark"><span><x-icon name="arrow-right" :size="28" /></span></span>
                        <span class="s-tile-text"><b>All nuts</b><span>See everything</span></span>
                    </a>
                </div>
            </section>
        @endif

        {{-- 3. Best sellers ---------------------------------------------------------------------- --}}
        <section class="s-section" id="best" aria-labelledby="best-title">
            <div class="s-section-head" data-reveal>
                <div><span class="s-eyebrow">Most loved</span><h2 id="best-title">Best sellers{{ $branch ? ' at '.$branch['name'] : '' }}</h2></div>
                <a href="{{ route('shop.search') }}">Shop all nuts <x-icon name="arrow-right" :size="16" /></a>
            </div>
            @if ($popular)
                <div class="s-grid">
                    @foreach (array_slice($popular, 0, 4) as $i => $p)
                        @include('shop.partials.card', ['p' => $p, 'branch' => $branch, 'i' => $i])
                    @endforeach
                </div>
            @else
                <div class="s-empty">
                    <span class="s-empty-icon"><x-icon name="leaf" :size="30" /></span>
                    <h3>Fresh batches on the way</h3>
                    <p>Our shelves are being restocked. Please check back soon.</p>
                </div>
            @endif
        </section>

        {{-- 4. How pickup works ------------------------------------------------------------------ --}}
        <section class="s-section" id="how" aria-labelledby="how-title">
            <div class="s-section-head" data-reveal>
                <div><span class="s-eyebrow">Store pickup</span><h2 id="how-title">How pickup works</h2>
                    <p>No delivery fees, no waiting at the counter. Your order is packed and ready when you arrive.</p></div>
            </div>
            <ol class="s-how" style="list-style:none;margin:0;padding:0">
                <li class="s-step" data-reveal>
                    <div class="s-step-top"><span class="s-step-icon"><x-icon name="bag" :size="30" :stroke="1.6" /></span><span class="s-step-n" aria-hidden="true">01</span></div>
                    <h3>Pick your nuts</h3>
                    <p>Add your favourites to the cart. We pick your nearest branch for you.</p>
                </li>
                <li class="s-step" data-reveal style="--d: .08s">
                    <div class="s-step-top"><span class="s-step-icon"><x-icon name="wallet" :size="30" :stroke="1.6" /></span><span class="s-step-n" aria-hidden="true">02</span></div>
                    <h3>Pay your way</h3>
                    <p>Pay online with GCash, QR Ph or card, or pay in cash at the counter when you pick up.</p>
                </li>
                <li class="s-step" data-reveal style="--d: .16s">
                    <div class="s-step-top"><span class="s-step-icon"><x-icon name="store" :size="30" :stroke="1.6" /></span><span class="s-step-n" aria-hidden="true">03</span></div>
                    <h3>Pick it up</h3>
                    <p>We'll let you know when it's ready. Show your order number at the branch.</p>
                </li>
            </ol>
        </section>

        {{-- 5. Golden Kernel points ---------------------------------------------------------------- --}}
        <section class="s-loyal" aria-labelledby="loyal-title" data-reveal>
            <div class="copy">
                <span class="s-eyebrow">Golden Kernel rewards</span>
                <h2 id="loyal-title">Every pickup earns you points.</h2>
                <p>Collect Golden Kernel points on completed orders and use them for money off your next bag, here or in the Melai Nuts app.</p>
                @if ($shopCustomer ?? null)
                    <a href="{{ route('shop.points') }}" class="s-btn dark">See my points <x-icon name="arrow-right" :size="17" class="ico-arrow" /></a>
                @elseif (! ($shopStaff ?? null))
                    <a href="{{ route('shop.register') }}" class="s-btn dark">Create a free account <x-icon name="arrow-right" :size="17" class="ico-arrow" /></a>
                @endif
            </div>
            <div class="coin" aria-hidden="true"><span><b>+pts</b>on every order</span></div>
        </section>

        {{-- 6. Branches -------------------------------------------------------------------------- --}}
        @if ($shopBranches)
            <section class="s-section" aria-labelledby="branch-title">
                <div class="s-section-head" data-reveal>
                    <div><span class="s-eyebrow">Visit us</span><h2 id="branch-title">Our branches</h2></div>
                </div>
                <div class="s-branches">
                    @foreach ($shopBranches as $n => $b)
                        <article @class(['s-branch-card', 'is-mine' => $branch && $branch['id'] === $b['id']]) data-reveal style="--d: {{ $n * 0.07 }}s">
                            @if ($branch && $branch['id'] === $b['id'])<span class="s-mine">Your pickup branch</span>@endif
                            <h3>{{ $b['name'] }}</h3>
                            @if ($b['address'] !== '')<div class="s-brow"><x-icon name="map-pin" :size="16" /><span>{{ $b['address'] }}</span></div>@endif
                            <div class="s-brow"><x-icon name="clock" :size="16" /><span>{{ $b['hours'] ?: 'Hours not set' }}</span></div>
                            @if ($b['phone'])<div class="s-brow"><x-icon name="phone" :size="16" /><span>{{ $b['phone'] }}</span></div>@endif
                            @if ($b['latitude'] !== null && $b['longitude'] !== null)
                                <div class="actions">
                                    <a class="s-btn ghost sm" href="https://www.google.com/maps/search/?api=1&query={{ $b['latitude'] }},{{ $b['longitude'] }}" target="_blank" rel="noopener">
                                        <x-icon name="map-pin" :size="15" />Open in Maps</a>
                                </div>
                            @endif
                        </article>
                    @endforeach
                </div>
            </section>
        @endif
    @endif
@endsection
