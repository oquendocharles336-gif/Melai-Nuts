@extends('layouts.panel')
@section('title', 'Orders · Melai Nuts Admin')
@section('page-title', 'Orders')
@section('page-sub', 'Every order from the last '.$windowDays.' days. Click a row for details and to move it along.')
@section('page-actions')
    <x-button variant="primary" icon="plus" x-on:click="$dispatch('open-modal', 'new-order')">New order</x-button>
@endsection
@section('panel')
@include('partials.flash')

<div x-data="ordersPage(@js($orders), { advanceUrl: @js(route('orders.advance', '__ID__')), live: @js($liveData), open: @js($open) })" class="stack">
    <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center;justify-content:space-between">
        <div class="chips" role="group" aria-label="Filter by stage">
            @foreach (['all' => 'All', 'new' => 'New', 'packing' => 'Packing', 'shipped' => 'Shipped', 'delivered' => 'Delivered', 'other' => 'Cancelled & refunds'] as $k => $v)
                <button type="button" class="chip" :class="status === '{{ $k }}' && 'is-on'" :aria-pressed="status === '{{ $k }}'" x-on:click="status = '{{ $k }}'">{{ $v }} <span class="n" x-text="count('{{ $k }}')"></span></button>
            @endforeach
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
            @if (count($branches) > 1)
                <select class="select" x-model="branch" aria-label="Branch" style="width:auto;height:34px">
                    <option value="">All branches</option>
                    @foreach ($branches as $b)<option value="{{ $b['id'] }}">{{ $b['name'] }}</option>@endforeach
                </select>
            @endif
            <label class="input-icon" style="min-width:240px"><span class="sr-only">Search orders</span><x-icon name="search" :size="15" />
                <input class="input" style="height:34px" type="search" x-model.debounce.150ms="q" placeholder="Order, customer or product  /" data-page-search></label>
        </div>
    </div>

    <x-card flush>
        <x-table stack>
            <x-slot:head><th>Order</th><th>Customer</th><th>Placed</th><th>Items</th><th class="r">Total</th><th>Payment</th><th>Status</th></x-slot:head>
            <template x-for="r in visible" :key="r.id">
                <tr class="is-click" tabindex="0" x-on:click="show(r.id)" x-on:keydown.enter="show(r.id)" :aria-label="'Open order ' + r.id">
                    <td><span class="cell-strong" x-text="r.id"></span><div class="cell-sub" x-text="r.branchName + (r.isPos ? ' · in-store' : (r.isDelivery ? ' · delivery' : ' · pickup'))"></div></td>
                    <td><span class="who"><span class="avatar sm" x-text="$initials(r.customer)"></span><span x-text="r.customer"></span></span></td>
                    <td class="cell-sub" style="white-space:nowrap" x-text="$datetime(r.placedAt)"></td>
                    <td data-label="Items" class="cell-sub" x-text="r.items.length + (r.items.length === 1 ? ' item' : ' items')"></td>
                    <td class="r num"><span class="cell-strong" x-text="$peso(r.total)"></span>
                        <div class="cell-sub" x-show="r.refunded > 0" x-text="'− ' + $peso(r.refunded) + ' refunded'"></div>
                        <div class="cell-sub" x-show="r.pendingRefund > 0" x-text="$peso(r.pendingRefund) + ' refund pending'"></div></td>
                    <td data-label="Payment"><span class="badge no-dot" :class="{ ok: r.payment === 'paid', warn: r.payment === 'pending', bad: r.payment === 'failed', info: r.payment === 'refunded' }" x-text="r.method + ' · ' + (r.payment || '—')"></span></td>
                    <td><span class="badge" :class="r.tone" x-text="r.statusLabel"></span></td>
                </tr>
            </template>
            <tr x-show="!filtered.length"><td colspan="7" class="empty">No orders match.</td></tr>
        </x-table>
        <div style="padding:12px 16px;border-top:1px solid var(--line);display:flex;justify-content:space-between;align-items:center;gap:10px" x-show="filtered.length">
            <span class="cell-sub" x-text="'Showing ' + visible.length + ' of ' + filtered.length"></span>
            <button class="btn sm" type="button" x-show="filtered.length > visible.length" x-on:click="limit += 60">Show more</button>
        </div>
    </x-card>

    {{-- Detail drawer --}}
    <x-drawer show="selected !== null" close="close()" label="Order details">
        <template x-if="selected">
            <div style="display:contents">
                <div class="drawer-head">
                    <div class="who"><span class="avatar lg" x-text="$initials(selected.customer)"></span>
                        <div><div class="cell-strong" style="font-size:16px" x-text="selected.customer"></div><div class="cell-sub" x-text="selected.id + ' · ' + selected.branchName"></div></div></div>
                    <button class="btn ghost icon" type="button" x-on:click="close()" aria-label="Close"><x-icon name="x" /></button>
                </div>
                <div class="drawer-body">
                    <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                        <span class="badge" :class="selected.tone" x-text="selected.statusLabel"></span>
                        <span class="badge no-dot" x-text="selected.isPos ? 'In-store' : (selected.isDelivery ? 'Delivery' : 'Pickup')"></span>
                        <span class="badge no-dot" :class="selected.payment === 'paid' ? 'ok' : (selected.payment === 'pending' ? 'warn' : '')" x-text="selected.method + ' · ' + (selected.payment || '—')"></span>
                    </div>
                    <div x-show="selected.stage" style="padding:6px 0 2px"><x-stepper state="(i) => stepState(selected, i)" :steps="['New', 'Packing', 'Shipped', 'Delivered']" /></div>
                    <p class="note" x-show="selected.isDelivery && !selected.next" style="margin:0" data-app-only>This order is handled in the Melai Nuts app (staff portal). The website shows it for sales and refunds only.</p>
                    <p class="note" x-show="!selected.stage" style="margin:0">This order left the normal flow (<span x-text="selected.statusLabel.toLowerCase()"></span>), so it has no next stage.</p>
                    <dl class="dl">
                        <div><dt>Items</dt><dd x-text="selected.items.length"></dd></div>
                        <div><dt>Total</dt><dd x-text="$peso(selected.total)"></dd></div>
                        <div><dt>Placed</dt><dd x-text="$datetime(selected.placedAt)"></dd></div>
                    </dl>
                    <div><div class="form-label">Order lines</div>
                        <ul class="lines"><template x-for="(line, i) in selected.items" :key="i"><li><span x-text="line"></span></li></template>
                            <li><b>Total</b><b class="tabular" x-text="$peso(selected.total)"></b></li></ul></div>
                    <dl class="dl" x-show="selected.refundState && selected.refundState !== 'none'" data-refund-summary>
                        <div><dt>Refunded</dt><dd x-text="selected.refunded === null ? '—' : $peso(selected.refunded) + (selected.refundState === 'partial' ? ' (partial)' : (selected.refundState === 'full' ? ' (full)' : ''))"></dd></div>
                        <div><dt>Units refunded</dt><dd x-text="selected.refundedUnits ?? '—'"></dd></div>
                        <div><dt>Refund pending</dt><dd x-text="selected.pendingRefund ? $peso(selected.pendingRefund) + ' (not deducted yet)' : '—'"></dd></div>
                        <div><dt>Points reversed</dt><dd x-text="selected.pointsReversed ?? '—'"></dd></div>
                    </dl>
                    <p class="note" x-show="selected.refund" style="margin:0" x-text="'Refund: ' + (selected.refund || '').replace('_', ' ') + '. Refunds are handled on the Refunds page.'"></p>
                </div>
                <div class="drawer-foot">
                    <button type="button" class="btn" x-on:click="close()">Close</button>
                    <button type="button" class="btn primary" x-show="selected.next" :class="busy && 'is-busy'" x-on:click="advance()" :disabled="!live">
                        <span class="spinner" x-show="busy" x-cloak></span><span x-text="'Move to next stage · ' + (selected.nextLabel || '')"></span></button>
                </div>
            </div>
        </template>
    </x-drawer>
    @unless ($liveData)<p class="note">Move to next stage and New order write to the Melai Nuts app database, so they are switched off on test data.</p>@endunless
</div>
@endsection
