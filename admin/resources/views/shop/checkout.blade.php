@extends('layouts.shop')

@section('title', 'Checkout')

@section('content')
    @include('shop.partials.steps', ['current' => 1])
    <h1 class="s-title">Checkout</h1>

    <form method="POST" action="{{ route('shop.checkout.place') }}" class="s-layout" id="checkout">
        @csrf
        <div style="display:grid;gap:18px;min-width:0">
            <section class="s-panel" aria-labelledby="pickup-title">
                <h2 id="pickup-title">Store pickup</h2>
                @php($b = $cart['branch'])
                <div class="s-pickup">
                    <b>{{ $b['name'] }}</b>
                    @if ($b['address'] !== '')<div><x-icon name="map-pin" :size="15" /><span>{{ $b['address'] }}</span></div>@endif
                    <div><x-icon name="clock" :size="15" /><span>{{ $b['hours'] ?: 'Hours not set' }}</span></div>
                    @if ($b['phone'])<div><x-icon name="phone" :size="15" /><span>{{ $b['phone'] }}</span></div>@endif
                </div>
                <p class="s-note">Your branch is picked automatically: the nearest one when you share your location, otherwise your last pickup branch.</p>
            </section>

            <section class="s-panel" aria-labelledby="contact-title">
                <h2 id="contact-title">Contact</h2>
                @if (trim($phone) !== '')
                    <p class="s-sub" style="margin:0">The branch will contact you at <b>{{ $phone }}</b> about this order.</p>
                @else
                    <div class="s-field @error('phone') has-err @enderror">
                        <label for="phone">Mobile number</label>
                        <input id="phone" type="tel" name="phone" value="{{ old('phone') }}" placeholder="09171234567" maxlength="16" autocomplete="tel" inputmode="tel" required>
                        <span class="hint">The branch uses this to reach you about your pickup. It's saved to your account.</span>
                        @error('phone')<span class="err">{{ $message }}</span>@enderror
                    </div>
                @endif
                <div class="s-field @error('notes') has-err @enderror">
                    <label for="notes">Notes for the branch <span class="hint">(optional)</span></label>
                    <textarea id="notes" name="notes" maxlength="{{ \App\Http\Requests\Rules::NOTE_MAX }}" placeholder="Pasalubong packing, pickup time…">{{ old('notes') }}</textarea>
                    @error('notes')<span class="err">{{ $message }}</span>@enderror
                </div>
            </section>

            <section class="s-panel" aria-labelledby="pay-title">
                <h2 id="pay-title">Payment</h2>
                @php($isFirst = $first !== null && $first['first_order'])
                @php($firstBlocked = $isFirst && ($first['pending_order_id'] !== null || ! $first['online_payment_enabled']))
                @if ($first === null)
                    {{-- The first-order check could not be loaded: never guess, offer a retry. --}}
                    <div class="s-flash bad" role="alert"><x-icon name="alert" :size="18" />
                        <span>We couldn't load your payment options. <a href="{{ route('shop.checkout') }}">Try again</a>.</span>
                    </div>
                @elseif ($isFirst && $first['pending_order_id'] !== null)
                    <div class="s-flash note" role="status"><x-icon name="clock" :size="18" />
                        <span>Your first order {{ $first['pending_order_id'] }} is still waiting for its online payment. Pay for it, or wait for it to expire, before placing another order.
                            <a href="{{ route('shop.orders.show', $first['pending_order_id']) }}">Pay for this order</a></span>
                    </div>
                @elseif ($isFirst && ! $first['online_payment_enabled'])
                    <div class="s-flash note" role="status"><x-icon name="alert" :size="18" />
                        <span>Your first order is paid online, and online payment is unavailable right now. Please try again later.</span>
                    </div>
                @elseif ($isFirst)
                    <div class="s-flash note" role="note"><x-icon name="gift" :size="18" />
                        <span><b>Your first order.</b> Welcome to Melai Nuts! Your first order is paid online, half or in full, before we prepare it. This is a one-time step: from your next order you can also pay in cash. Pay within {{ $first['expiry_minutes'] }} minutes, or the order is cancelled and nothing is charged.</span>
                    </div>
                    <div style="display:grid;gap:10px" role="radiogroup" aria-labelledby="pay-title">
                        <label class="s-option">
                            <input type="radio" name="payment" value="half" @checked(old('payment') === 'half') required>
                            <span><x-icon name="wallet" :size="20" /><b>Pay 50% now</b>
                                <small>{{ \App\Support\Format::peso($first['half_amount']) }} online now, then {{ \App\Support\Format::peso($first['half_balance']) }} in cash when you pick it up.</small>
                            </span>
                        </label>
                        <label class="s-option">
                            <input type="radio" name="payment" value="full" @checked(old('payment') === 'full') required>
                            <span><x-icon name="wallet" :size="20" /><b>Pay 100% now</b>
                                <small>{{ \App\Support\Format::peso($first['full_amount']) }} online now, nothing left to pay later.</small>
                            </span>
                        </label>
                    </div>
                @else
                <div style="display:grid;gap:10px" role="radiogroup" aria-labelledby="pay-title">
                    <label class="s-option">
                        <input type="radio" name="payment" value="counter" @checked(old('payment', 'counter') === 'counter')>
                        <span><x-icon name="banknote" :size="20" /><b>Cash on counter pickup</b>
                            <small>
                                @if ($quote)
                                    Pay {{ \App\Support\Format::peso($quote['amount']) }} online now (a {{ rtrim(rtrim(number_format($quote['percent'] ?? 0, 2), '0'), '.') }}% downpayment), and the rest, {{ \App\Support\Format::peso($quote['balance']) }}, in cash at pickup.
                                @else
                                    Pay the full amount in cash when you pick up.
                                @endif
                            </small>
                        </span>
                    </label>
                    <label class="s-option">
                        <input type="radio" name="payment" value="online" @checked(old('payment') === 'online') @disabled(! $online['enabled'])>
                        <span><x-icon name="wallet" :size="20" /><b>Pay online now</b>
                            <small>{{ $online['enabled'] ? 'GCash, QR Ph or card through HitPay.' : $online['message'] }}</small>
                        </span>
                    </label>
                </div>
                @endif
                @if ($quote)
                    <div class="s-flash note"><x-icon name="clock" :size="18" />
                        <span>Pickup orders need the online downpayment{{ $quote['expiry_minutes'] ? ' within '.$quote['expiry_minutes'].' minutes' : '' }}, or the order is cancelled and the stock goes back on the shelf.{{ $quote['pickup_days'] ? ' Please pick up within '.$quote['pickup_days'].' '.\Illuminate\Support\Str::plural('day', $quote['pickup_days']).' of "Ready for pickup".' : '' }}</span>
                    </div>
                @endif
                @error('payment')<span class="err" style="color:var(--bad)">{{ $message }}</span>@enderror
            </section>
        </div>

        <aside class="s-panel s-sticky" aria-label="Order summary">
            <h2>Your order</h2>
            <div class="s-lines">
                @foreach ($cart['lines'] as $line)
                    <div class="s-line" style="grid-template-columns:48px minmax(0,1fr) auto;gap:10px;padding:10px 0">
                        <div class="s-thumb" style="width:48px;height:48px;border-radius:12px;--tint: {{ \App\Services\Shop\ShopCatalog::tintFor(\App\Services\Shop\ShopCatalog::artFor($line['name'])) }}">
                            @if ($line['image'])<img src="{{ $line['image'] }}" alt="" loading="lazy">@else @include('shop.partials.art', ['kind' => \App\Services\Shop\ShopCatalog::artFor($line['name']), 'label' => $line['name']]) @endif
                        </div>
                        <div style="min-width:0"><b style="font-size:14px">{{ $line['name'] }}</b><small>{{ $line['qty'] }} × {{ $line['variant_label'] }}</small></div>
                        <span class="tabular">{{ \App\Support\Format::peso($line['line_total']) }}</span>
                    </div>
                @endforeach
            </div>
            <div class="s-sum">
                <div><span>Subtotal</span><span>{{ \App\Support\Format::peso($cart['subtotal']) }}</span></div>
                @if ($cart['voucher_discount'] > 0)<div class="good"><span>Voucher</span><span>−{{ \App\Support\Format::peso($cart['voucher_discount']) }}</span></div>@endif
                @if ($cart['loyalty_discount'] > 0)<div class="good"><span>Points</span><span>−{{ \App\Support\Format::peso($cart['loyalty_discount']) }}</span></div>@endif
                <div><span>Store pickup</span><span>Free</span></div>
                <div class="total"><span>Total</span><span>{{ \App\Support\Format::peso($cart['total']) }}</span></div>
                @if ($quote)
                    <div><span>Pay online now</span><b>{{ \App\Support\Format::peso($quote['amount']) }}</b></div>
                    <div><span>Cash at pickup</span><span>{{ \App\Support\Format::peso($quote['balance']) }}</span></div>
                @endif
                @if ($isFirst && ! $firstBlocked)
                    <div><span>Pay 50% now</span><span>{{ \App\Support\Format::peso($first['half_amount']) }} + {{ \App\Support\Format::peso($first['half_balance']) }} cash</span></div>
                    <div><span>Pay 100% now</span><span>{{ \App\Support\Format::peso($first['full_amount']) }}</span></div>
                @endif
            </div>
            <button type="submit" class="s-btn primary block" form="checkout" @disabled($first === null || $firstBlocked)>{{ $isFirst || $quote || old('payment') === 'online' ? 'Place order & pay' : 'Place order' }}</button>
            <p class="s-note">By placing your order you agree to our <a href="{{ route('legal.terms') }}" target="_blank" rel="noopener">Terms</a>. Online payments are processed by HitPay.</p>
        </aside>
    </form>
@endsection
