@extends('layouts.shop')

@section('title', 'Your cart')

@section('content')
    @include('shop.partials.steps', ['current' => 0])
    <h1 class="s-title">Your cart</h1>

    @if ($error)
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="alert" :size="28" /></span>
            <h3>We couldn't load your cart</h3>
            <p>{{ $error }}</p>
            <a href="{{ route('shop.cart') }}" class="s-btn primary">Try again</a>
        </div>
    @elseif ($cart['lines'] === [])
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="bag" :size="28" /></span>
            <h3>Your cart is empty</h3>
            <p>Browse the shop and add some freshly roasted nuts.</p>
            <a href="{{ route('shop.search') }}" class="s-btn primary">Browse the shop</a>
        </div>
    @else
        <div class="s-layout">
            <section class="s-panel" aria-label="Items">
                <div class="s-lines">
                    @foreach ($cart['lines'] as $line)
                        <div class="s-line">
                            <div class="s-thumb">
                                @if ($line['image'])<img src="{{ $line['image'] }}" alt="" loading="lazy">@else{{ mb_strtoupper(mb_substr($line['name'], 0, 1)) }}@endif
                            </div>
                            <div style="min-width:0">
                                <a href="{{ route('shop.product', $line['product_id']) }}" class="s-line-name">{{ $line['name'] }}</a>
                                <small>{{ $line['variant_label'] }}{{ $line['variant_label'] !== '' ? ' · ' : '' }}{{ \App\Support\Format::peso($line['unit_price']) }} each</small>
                            </div>
                            <div class="s-line-right">
                                <b class="tabular">{{ \App\Support\Format::peso($line['line_total']) }}</b>
                                <div style="display:flex;gap:6px;align-items:center">
                                    <form method="POST" action="{{ route('shop.cart.update', $line['variant_id']) }}" data-autosubmit>
                                        @csrf @method('PATCH')
                                        <input type="hidden" name="product" value="{{ $line['product_id'] }}">
                                        <div class="s-qty" role="group" aria-label="Quantity of {{ $line['name'] }}">
                                            <button type="button" data-step="-1" aria-label="One less"><x-icon name="minus" :size="14" /></button>
                                            <input type="number" name="qty" value="{{ $line['qty'] }}" min="1" max="{{ \App\Services\Shop\ShopCart::MAX_QTY }}" inputmode="numeric" aria-label="Quantity">
                                            <button type="button" data-step="1" aria-label="One more"><x-icon name="plus" :size="14" /></button>
                                        </div>
                                        <noscript><button class="s-btn ghost sm">Update</button></noscript>
                                    </form>
                                    <form method="POST" action="{{ route('shop.cart.update', $line['variant_id']) }}">
                                        @csrf @method('PATCH')
                                        <input type="hidden" name="product" value="{{ $line['product_id'] }}">
                                        <input type="hidden" name="qty" value="0">
                                        <button type="submit" class="s-icon-btn" aria-label="Remove {{ $line['name'] }}" title="Remove"><x-icon name="trash" :size="17" /></button>
                                    </form>
                                </div>
                            </div>
                        </div>
                    @endforeach
                </div>
            </section>

            <aside class="s-panel s-sticky" aria-label="Order summary">
                <h2>Order summary</h2>
                @if ($cart['branch'])
                    <div class="s-pickup">
                        <div><x-icon name="store" :size="16" /><span>Pickup at <b>{{ $cart['branch']['name'] }}</b></span></div>
                    </div>
                @else
                    <div class="s-flash note"><x-icon name="map-pin" :size="18" /><span>Choose your pickup branch to check out. <button type="button" class="s-link-btn" data-locate>Use my location</button></span></div>
                @endif

                @if ($cart['guest'])
                    <p class="s-note"><x-icon name="coins" :size="14" /> Sign in at checkout to use Golden Kernel points or a voucher. Your cart is saved in this browser until then.</p>
                @else
                    @if ($cart['voucher_code'])
                        <form method="POST" action="{{ route('shop.cart.voucher.remove') }}" class="s-inline">
                            @csrf @method('DELETE')
                            <span class="s-status ok" style="flex:1"><x-icon name="check" :size="14" /> Voucher {{ $cart['voucher_code'] }} applied</span>
                            <button class="s-btn ghost sm">Remove</button>
                        </form>
                    @else
                        <form method="POST" action="{{ route('shop.cart.voucher') }}" class="s-inline">
                            @csrf
                            <div class="s-field @error('code') has-err @enderror">
                                <label for="code" class="sr-only">Voucher code</label>
                                <input id="code" type="text" name="code" value="{{ old('code') }}" placeholder="Voucher code" maxlength="30" autocapitalize="characters" autocomplete="off">
                                @error('code')<span class="err">{{ $message }}</span>@enderror
                            </div>
                            <button class="s-btn ghost" style="align-self:start">Apply</button>
                        </form>
                    @endif
                    @if ($cart['points_balance'] > 0)
                        <form method="POST" action="{{ route('shop.cart.points') }}">
                            @csrf
                            <input type="hidden" name="on" value="{{ $cart['redeem_points'] ? 0 : 1 }}">
                            <button class="s-btn ghost block sm"><x-icon name="coins" :size="15" />{{ $cart['redeem_points'] ? 'Stop using points' : 'Use my '.number_format($cart['points_balance']).' points' }}</button>
                        </form>
                    @endif
                @endif

                <div class="s-sum">
                    <div><span>Subtotal ({{ $cart['count'] }} {{ \Illuminate\Support\Str::plural('pack', $cart['count']) }})</span><span>{{ \App\Support\Format::peso($cart['subtotal']) }}</span></div>
                    @if ($cart['voucher_discount'] > 0)<div class="good"><span>Voucher</span><span>−{{ \App\Support\Format::peso($cart['voucher_discount']) }}</span></div>@endif
                    @if ($cart['loyalty_discount'] > 0)<div class="good"><span>Points</span><span>−{{ \App\Support\Format::peso($cart['loyalty_discount']) }}</span></div>@endif
                    <div class="total"><span>Total</span><span>{{ \App\Support\Format::peso($cart['total']) }}</span></div>
                </div>
                <p class="s-note">The branch confirms the final total when you place your order.</p>

                @if ($cart['guest'])
                    <a href="{{ route('shop.checkout') }}" class="s-btn primary block">Sign in to check out <x-icon name="arrow-right" :size="16" /></a>
                @else
                    <a href="{{ route('shop.checkout') }}" class="s-btn primary block" @if (! $cart['branch']) aria-disabled="true" @endif>Proceed to checkout <x-icon name="arrow-right" :size="16" /></a>
                @endif
            </aside>
        </div>
    @endif
@endsection
