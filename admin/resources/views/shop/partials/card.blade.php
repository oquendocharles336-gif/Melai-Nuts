{{-- One product card. $p = ShopCatalog product, $branch = current pickup branch or null. --}}
@php
    $available = collect($p['variants'])->first(fn ($v) => ! $branch || $v['stock'] > 0);
    $several = count($p['variants']) > 1;
    $url = route('shop.product', $p['id']);
    $art = $p['art'] ?? \App\Services\Shop\ShopCatalog::artFor($p['name']);
@endphp
<article class="s-card" data-reveal style="--d: {{ ($i ?? 0) % 4 * 0.07 }}s">
    <a href="{{ $url }}" class="s-card-link" aria-label="{{ $p['name'] }}, {{ \App\Support\Format::peso($p['price'], 0) }}"></a>
    <div @class(['s-photo', 's-skel' => (bool) $p['images']]) style="--tint: {{ \App\Services\Shop\ShopCatalog::tintFor($art) }}" data-fly-src>
        @if ($p['images'])
            <img src="{{ $p['images'][0] }}" alt="" loading="lazy" decoding="async" data-skel-img>
        @else
            @include('shop.partials.art', ['kind' => $art, 'label' => $p['name']])
        @endif
        @if ($p['badge'])
            <span class="s-pill left">{{ $p['badge'] }}</span>
        @endif
        {{-- Stock badges only once a branch is chosen (no clutter before). --}}
        @if ($branch && $p['stock'] <= 0)
            <span class="s-pill right out">Out of stock</span>
        @elseif ($branch && $p['only_left'])
            <span class="s-pill right low">Only {{ $p['only_left'] }} left</span>
        @endif
    </div>
    <div class="s-card-body">
        <h3 class="s-card-name">{{ $p['name'] }}</h3>
        <span class="s-card-meta">{{ $several ? count($p['variants']).' sizes' : ($p['variants'][0]['label'] ?? '') }}</span>
    </div>
    <div class="s-card-foot">
        <div class="s-price">
            <b>{{ \App\Support\Format::peso($p['price'], 0) }}</b>
            @if ($p['original_price'] && $p['original_price'] > $p['price'])
                <s>{{ \App\Support\Format::peso($p['original_price'], 0) }}</s>
            @endif
        </div>
        @if ($shopStaff ?? null)
            <a href="{{ $url }}" class="s-btn ghost s-add">View</a>
        @elseif ($several)
            <a href="{{ $url }}" class="s-btn ghost s-add">Choose size</a>
        @elseif ($available && (! $branch || $p['stock'] > 0))
            <form method="POST" action="{{ route('shop.cart.add') }}" data-add-to-cart>
                @csrf
                <input type="hidden" name="product" value="{{ $p['id'] }}">
                <input type="hidden" name="variant" value="{{ $available['id'] }}">
                <button type="submit" class="s-btn primary s-add" aria-label="Add {{ $p['name'] }} to cart"><x-icon name="plus" :size="16" />Add</button>
            </form>
        @else
            <button type="button" class="s-btn ghost s-add" disabled>Sold out</button>
        @endif
    </div>
</article>
