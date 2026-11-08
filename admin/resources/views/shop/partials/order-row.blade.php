@php
    $tone = match ($o['status']) {
        'completed' => 'ok',
        'cancelled', 'refunded' => 'bad',
        'awaitingDownpayment', 'refundRequested' => 'warn',
        default => 'brand',
    };
    $count = array_sum(array_column($o['items'], 'qty'));
@endphp
<a href="{{ route('shop.orders.show', $o['id']) }}" class="s-order-row">
    <div style="min-width:0">
        <b>Order {{ $o['id'] }}</b>
        <small style="display:block">{{ \Illuminate\Support\Carbon::parse($o['created_at'])->timezone('Asia/Manila')->format('M j, Y · g:i A') }} · {{ $o['branch_name'] }}</small>
        <small style="display:block">{{ $count }} {{ \Illuminate\Support\Str::plural('item', $count) }} · {{ \App\Support\Format::peso($o['total']) }}</small>
    </div>
    <span class="s-status {{ $tone }}">{{ $o['status_label'] }}</span>
</a>
