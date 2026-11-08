{{-- One product card. $p = ShopCatalog product, $branch = current pickup branch or null. --}}
@php
    $available = collect($p['variants'])->first(fn ($v) => ! $branch || $v['stock'] > 0);
    $several = count($p['variants']) > 1;
    $url = route('shop.product', $p['id']);
@endphp
<article class="s-card">
    <a href="{{ $url }}" class="s-card-link" aria-label="{{ $p['name'] }}, {{ \App\Support\Format::peso($p['price'], 0) }}"></a>
    <div class="s-photo">
        @if ($p['images'])
            <img src="{{ $p['images'][0] }}" alt="" loading="lazy" decoding="async">
        @else
            <span class="s-initial" aria-hidden="true">{{ mb_strtoupper(mb_substr($p['name'], 0, 1)) }}</span>
        @endif
        @if ($p['badge'])
            <span class="s-pill left">{{ $p['badge'] }}</span>
        @endif
        @if (! $branch)
            {{-- No stock badges until a branch is chosen (no clutter). --}}
        @elseif ($p['stock'] <= 0)
            <span class="s-pill right out">Out of stock</span>
        @elseif ($p['only_left'])
            <span class="s-pill right low">Only {{ $p['only_left'] }} left</span>
        @endif
    </div>
    <div class="s-card-body">
        <h3 class="s-card-name">{{ $p['name'] }}</h3>
        @if ($several)
            <span class="s-card-meta">{{ count($p['variants']) }} sizes</span>
        @elseif (($p['variants'][0]['label'] ?? '') !== '')
            <span class="s-card-meta">{{ $p['variants'][0]['label'] }}</span>
        @endif
        <div class="s-price">
            <b>{{ \App\Support\Format::peso($p['price'], 0) }}</b>
            @if ($p['original_price'] && $p['original_price'] > $p['price'])
                <s>{{ \App\Support\Format::peso($p['original_price'], 0) }}</s>
            @endif
        </div>
    </div>
    <div class="s-card-foot">
        @if ($shopStaff ?? null)
            <a href="{{ $url }}" class="s-btn ghost sm s-add">View</a>
        @elseif ($several)
            <a href="{{ $url }}" class="s-btn ghost sm s-add">Choose size</a>
        @elseif ($available && (! $branch || $p['stock'] > 0))
            <form method="POST" action="{{ route('shop.cart.add') }}" data-add-to-cart>
                @csrf
                <input type="hidden" name="product" value="{{ $p['id'] }}">
                <input type="hidden" name="variant" value="{{ $available['id'] }}">
                <button type="submit" class="s-btn primary sm s-add"><x-icon name="plus" :size="16" />Add to cart</button>
            </form>
        @else
            <button type="button" class="s-btn ghost sm s-add" disabled>Unavailable</button>
        @endif
    </div>
</article>
