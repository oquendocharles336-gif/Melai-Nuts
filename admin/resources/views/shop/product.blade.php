@extends('layouts.shop')

@section('title', $product['name'])

@section('content')
    @php
        $first = collect($product['variants'])->first(fn ($v) => ! $branch || $v['stock'] > 0) ?? ($product['variants'][0] ?? null);
        $canBuy = $first !== null && (! $branch || $product['stock'] > 0);
    @endphp
    <nav aria-label="Breadcrumb" class="s-crumbs"><a href="{{ route('shop.home') }}">Shop</a> / <a href="{{ route('shop.search') }}">All nuts</a> / <span aria-current="page">{{ $product['name'] }}</span></nav>

    <div class="s-product">
        @php($art = $product['art'] ?? \App\Services\Shop\ShopCatalog::artFor($product['name']))
        <div @class(['s-photo', 's-skel' => (bool) $product['images']]) style="--tint: {{ \App\Services\Shop\ShopCatalog::tintFor($art) }}" data-fly-src>
            @if ($product['images'])
                <img src="{{ $product['images'][0] }}" alt="{{ $product['name'] }}" data-skel-img>
            @else
                @include('shop.partials.art', ['kind' => $art, 'label' => $product['name']])
            @endif
            @if ($product['badge'])<span class="s-pill left">{{ $product['badge'] }}</span>@endif
        </div>

        <div class="s-product-info">
            <div>
                <h1>{{ $product['name'] }}</h1>
                <div class="s-price" style="margin-top:12px">
                    <b>{{ \App\Support\Format::peso($first['price'] ?? $product['price'], 0) }}</b>
                    @if ($product['original_price'] && $product['original_price'] > $product['price'])
                        <s>{{ \App\Support\Format::peso($product['original_price'], 0) }}</s>
                    @endif
                </div>
            </div>

            @if (! $branch)
                <span class="s-status warn"><x-icon name="map-pin" :size="14" /> Choose a branch to see stock</span>
            @elseif ($product['stock'] <= 0)
                <span class="s-status bad">Out of stock at {{ $branch['name'] }}</span>
            @elseif ($product['only_left'])
                <span class="s-status warn">Only {{ $product['only_left'] }} left at {{ $branch['name'] }}</span>
            @else
                <span class="s-status ok"><x-icon name="check" :size="14" /> In stock at {{ $branch['name'] }}</span>
            @endif

            @if ($product['description'] !== '')
                <p class="s-desc">{{ $product['description'] }}</p>
            @endif

            @if ($shopStaff ?? null)
                <span class="s-status brand"><x-icon name="shield" :size="14" /> Browse only: ordering needs a customer account.</span>
            @elseif ($product['variants'])
                <form method="POST" action="{{ route('shop.cart.add') }}" class="s-form" data-add-to-cart>
                    @csrf
                    <input type="hidden" name="product" value="{{ $product['id'] }}">
                    @if (count($product['variants']) > 1)
                        <fieldset class="s-field" style="border:0;padding:0;margin:0">
                            <legend class="lbl">Size</legend>
                            <div class="s-sizes">
                                @foreach ($product['variants'] as $v)
                                    <label class="s-size">
                                        <input type="radio" name="variant" value="{{ $v['id'] }}" @checked($first && $v['id'] === $first['id']) @disabled($branch && $v['stock'] <= 0)>
                                        <span><b>{{ $v['label'] }}</b><small>{{ \App\Support\Format::peso($v['price'], 0) }}{{ $branch && $v['stock'] <= 0 ? ' · out of stock' : '' }}</small></span>
                                    </label>
                                @endforeach
                            </div>
                        </fieldset>
                    @else
                        <input type="hidden" name="variant" value="{{ $product['variants'][0]['id'] }}">
                        @if ($product['variants'][0]['label'] !== '')<span class="s-card-meta">Pack: {{ $product['variants'][0]['label'] }}</span>@endif
                    @endif

                    <div class="s-buy">
                        <div class="s-qty" role="group" aria-label="Quantity">
                            <button type="button" data-step="-1" aria-label="One less"><x-icon name="minus" :size="16" /></button>
                            <input type="number" name="qty" value="1" min="1" max="{{ \App\Services\Shop\ShopCart::MAX_QTY }}" inputmode="numeric" aria-label="Quantity">
                            <button type="button" data-step="1" aria-label="One more"><x-icon name="plus" :size="16" /></button>
                        </div>
                        <button type="submit" class="s-btn primary" @disabled(! $canBuy)><x-icon name="bag" :size="18" />{{ $canBuy ? 'Add to cart' : 'Unavailable' }}</button>
                    </div>
                </form>
            @else
                <span class="s-status bad">Currently unavailable</span>
            @endif

            <div class="s-facts">
                <div><x-icon name="store" :size="16" /><span>Store pickup{{ $branch ? ' at '.$branch['name'] : '' }}. Bring your order number to the counter.</span></div>
                <div><x-icon name="coins" :size="16" /><span>Earn Golden Kernel points on every completed pickup.</span></div>
                <div><x-icon name="leaf" :size="16" /><span>Roasted in small batches and restocked weekly.</span></div>
            </div>
        </div>
    </div>

    @if ($related)
        <section class="s-section" aria-labelledby="rel-title">
            <div class="s-section-head"><div><span class="s-eyebrow">More to try</span><h2 id="rel-title">You might also like</h2></div></div>
            <div class="s-grid">
                @foreach ($related as $i => $p)
                    @include('shop.partials.card', ['p' => $p, 'branch' => $branch, 'i' => $i])
                @endforeach
            </div>
        </section>
    @endif
@endsection
