@extends('layouts.shop')

@section('title', 'Order '.$order['id'])

@section('content')
    @php
        $tone = match ($order['status']) {
            'completed' => 'ok',
            'cancelled', 'refunded' => 'bad',
            'awaitingDownpayment', 'refundRequested' => 'warn',
            default => 'brand',
        };
        $when = fn ($t) => $t ? \Illuminate\Support\Carbon::parse($t)->timezone('Asia/Manila')->format('M j, Y · g:i A') : '';
    @endphp

    @if ($placed || $checking)
        @include('shop.partials.steps', ['current' => 2])
    @endif

    @if ($checking && $order['can_pay'])
        <div class="s-flash note" role="status" data-poll-url="{{ route('shop.orders.status', $order['id']) }}" data-poll-status="{{ $order['status'] }}">
            <x-icon name="clock" :size="18" /><span>Checking your payment with HitPay… this page updates by itself.</span>
        </div>
    @elseif ($placed || $checking)
        <div class="s-confirm">
            <span class="tick"><x-icon name="check" :size="38" :stroke="2.4" /></span>
            <h1>Salamat po! Your order is in.</h1>
            <p>Order <b>{{ $order['id'] }}</b> was sent to {{ $order['branch_name'] }}.
                @if ($order['status'] === 'awaitingDownpayment')
                    Pay the downpayment to confirm it.
                @elseif ($order['paid_online'])
                    Your payment is confirmed.
                @else
                    We'll let you know when it's ready for pickup.
                @endif
            </p>
        </div>
    @endif

    <div class="s-layout">
        <div style="display:grid;gap:18px;min-width:0">
            <section class="s-panel">
                <div class="s-section-head">
                    <div>
                        <h1 class="s-title" style="font-size:1.4rem">Order {{ $order['id'] }}</h1>
                        <p class="s-sub">{{ $when($order['created_at']) }} · Pickup at {{ $order['branch_name'] }}</p>
                    </div>
                    <span class="s-status {{ $tone }}">{{ $order['status_label'] }}</span>
                </div>

                @if ($order['can_pay'])
                    <div class="s-flash note" style="justify-content:space-between;flex-wrap:wrap;align-items:center">
                        <span>
                            @if ($order['status'] === 'awaitingDownpayment' && $order['downpayment'])
                                Pay the {{ \App\Support\Format::peso($order['downpayment']['amount']) }} downpayment online to confirm this order.
                                @if ($order['downpayment']['expires_at']) It must be paid by {{ $when($order['downpayment']['expires_at']) }}. @endif
                            @else
                                This order is waiting for your online payment.
                            @endif
                        </span>
                        <form method="POST" action="{{ route('shop.orders.pay', $order['id']) }}">@csrf
                            <button class="s-btn primary sm"><x-icon name="wallet" :size="15" />Pay now</button>
                        </form>
                    </div>
                @endif

                <div class="s-lines">
                    @foreach ($order['items'] as $i)
                        <div class="s-line" style="grid-template-columns:minmax(0,1fr) auto">
                            <div><b>{{ $i['name'] }}</b><small>{{ $i['qty'] }} × {{ $i['variant'] }} · {{ \App\Support\Format::peso($i['unit_price']) }}</small></div>
                            <span class="tabular">{{ \App\Support\Format::peso($i['unit_price'] * $i['qty']) }}</span>
                        </div>
                    @endforeach
                </div>
                <div class="s-sum">
                    <div><span>Subtotal</span><span>{{ \App\Support\Format::peso($order['subtotal']) }}</span></div>
                    @if ($order['discount'] > 0)<div class="good"><span>Discounts</span><span>−{{ \App\Support\Format::peso($order['discount']) }}</span></div>@endif
                    <div class="total"><span>Total</span><span>{{ \App\Support\Format::peso($order['total']) }}</span></div>
                    @if ($order['downpayment'])
                        <div><span>Downpayment ({{ $order['downpayment']['status'] === 'success' ? 'paid' : 'due online' }})</span><span>{{ \App\Support\Format::peso($order['downpayment']['amount']) }}</span></div>
                        <div><span>Cash at pickup</span><span>{{ \App\Support\Format::peso(max(0, $order['total'] - $order['downpayment']['amount'])) }}</span></div>
                    @endif
                </div>
                @if ($order['notes'] !== '')<p class="s-note">Your note: {{ $order['notes'] }}</p>@endif
            </section>
        </div>

        <aside class="s-panel s-sticky">
            <h2>Progress</h2>
            @if ($order['events'])
                <ol class="s-timeline">
                    @foreach ($order['events'] as $e)
                        <li><b>{{ $e['label'] }}</b><small>{{ $when($e['at']) }}</small>@if ($e['note'] !== '')<small>{{ $e['note'] }}</small>@endif</li>
                    @endforeach
                </ol>
            @else
                <p class="s-sub">{{ $order['status_label'] }}</p>
            @endif
            <p class="s-note">Payment: {{ $order['payment_method'] }}{{ $order['paid_online'] ? ' · paid' : '' }}</p>
            @if ($order['points_earned'] > 0)<p class="s-note"><x-icon name="coins" :size="14" /> {{ $order['points_earned'] }} points earned</p>@endif
            <a href="{{ route('shop.orders') }}" class="s-btn ghost block sm">All orders</a>
        </aside>
    </div>
@endsection
