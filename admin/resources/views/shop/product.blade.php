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

    {{-- Ratings and reviews (migration 20261119020000). The list is loaded by shop.js from
         shop.product.reviews, with loading / empty / error and retry states. --}}
    @php($count = (int) ($product['review_count'] ?? 0))
    @php($mine = $myReview['review'] ?? null)
    @php($editing = $mine !== null || ($myReview['can_review'] ?? false))
    <section class="s-section" id="reviews" aria-labelledby="rev-title">
        <div class="s-section-head"><div><span class="s-eyebrow">From customers</span><h2 id="rev-title">Ratings &amp; reviews</h2></div></div>
        <div class="s-reviews">
            @if ($count > 0)
                <div class="s-reviews-summary">
                    <b>{{ number_format($product['rating'], 1) }}</b>
                    <div>
                        @include('shop.partials.stars', ['rating' => $product['rating']])
                        <div class="s-note">{{ $count }} {{ \Illuminate\Support\Str::plural('review', $count) }}</div>
                    </div>
                    <span class="sr-only">Rated {{ number_format($product['rating'], 1) }} out of 5</span>
                </div>
            @endif

            {{-- The customer's own review: only for a product they received (a completed order). --}}
            @if ($myReview !== null && ($myReview['error'] ?? false))
                <p class="s-note">We couldn't load your review right now. <a href="{{ route('shop.product', $product['id']) }}#reviews">Try again</a></p>
            @elseif ($editing && ! ($shopStaff ?? null))
                <form method="POST" action="{{ route('shop.product.review', $product['id']) }}" class="s-form" novalidate data-busy="Saving…" data-review-form>
                    @csrf
                    <fieldset @class(['s-field', 'has-err' => $errors->has('rating')]) style="border:0;padding:0;margin:0">
                        <legend class="lbl">{{ $mine ? 'Your review' : 'Rate this product' }}</legend>
                        @php($current = (int) old('rating', $mine['rating'] ?? 0))
                        <div class="s-rate" role="radiogroup" aria-label="Your rating">
                            @for ($i = 5; $i >= 1; $i--)
                                <input type="radio" id="rate-{{ $i }}" name="rating" value="{{ $i }}" @checked($current === $i) required>
                                <label for="rate-{{ $i }}" title="{{ $i }} {{ $i === 1 ? 'star' : 'stars' }}">★<span class="sr-only">{{ $i }} {{ $i === 1 ? 'star' : 'stars' }}</span></label>
                            @endfor
                        </div>
                        @error('rating')<span class="err">{{ $message }}</span>@enderror
                        @if ($mine && $mine['hidden'])<span class="hint">Hidden by Melai Nuts: other customers don't see it.</span>@endif
                    </fieldset>
                    <div @class(['s-field', 'has-err' => $errors->has('comment')])>
                        <label for="rev-comment">Comment (optional)</label>
                        <textarea id="rev-comment" name="comment" maxlength="{{ \App\Http\Requests\Rules::REVIEW_MAX }}" placeholder="What did you like about it?" data-review-comment data-moderate>{{ old('comment', $mine['comment'] ?? '') }}</textarea>
                        <span class="hint" data-review-count>{{ mb_strlen(old('comment', $mine['comment'] ?? '')) }} / {{ \App\Http\Requests\Rules::REVIEW_MAX }}</span>
                        @error('comment')<span class="err">{{ $message }}</span>@enderror
                    </div>
                    <div class="s-review-actions">
                        <button type="submit" class="s-btn primary"><x-icon name="check" :size="16" />{{ $mine ? 'Save changes' : 'Post review' }}</button>
                    </div>
                </form>
                @include('shop.partials.blocked-words')
                @if ($mine)
                    <form method="POST" action="{{ route('shop.product.review.destroy', $product['id']) }}" data-confirm="Delete your review of {{ $product['name'] }}?" data-confirm-title="Delete your review?" data-confirm-label="Delete">
                        @csrf @method('DELETE')
                        <button type="submit" class="s-btn ghost sm">Delete my review</button>
                    </form>
                @endif
            @elseif ($myReview !== null && ! ($shopStaff ?? null))
                <p class="s-note">You can review this product once an order with it is completed.</p>
            @elseif (! ($shopStaff ?? null))
                <p class="s-note"><a href="{{ \App\Support\AuthPanel::url(\App\Support\AuthPanel::SIGN_IN) }}" data-panel-open="{{ \App\Support\AuthPanel::SIGN_IN }}">Sign in</a> to review a product you received.</p>
            @endif

            <div class="s-review-list" data-reviews="{{ route('shop.product.reviews', $product['id']) }}" aria-live="polite">
                <p class="s-note" data-reviews-loading>Loading reviews…</p>
                <noscript><p class="s-note">Turn on JavaScript to read the reviews.</p></noscript>
            </div>
        </div>
    </section>

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
