@extends('layouts.panel')
@section('title', 'Stock · Melai Nuts Admin')
@section('page-title', 'Stock')
@php
    $branchName = collect($branches)->firstWhere('id', $branchId)['name'] ?? '';
    $items = collect($inventory['items'] ?? [])->map(fn ($i) => [
        'variant_id' => $i['variant_id'], 'product_id' => $i['product_id'] ?? null,
        'product' => $i['product_name'], 'variant' => $i['variant_label'] ?: 'Regular', 'sku' => $i['sku'] ?? null,
        'category' => $categories[$i['product_id'] ?? ''] ?? null,
        'qty' => (int) $i['quantity'], 'threshold' => $i['restock_threshold'] === null ? null : (int) $i['restock_threshold'], 'batched' => (int) $i['batched_quantity'],
        'price' => isset($i['price']) ? (float) $i['price'] : null,
    ])->values();
@endphp
@section('page-sub', 'Live stock in '.$branchName.'. Level bars show units on hand; the tick marks the restock level.')
@section('page-actions')
    <x-button icon="printer" x-on:click="$dispatch('stock-count-sheet')">Count sheet</x-button>
    <x-button variant="primary" icon="plus" x-on:click="$dispatch('stock-receive')">Receive stock</x-button>
@endsection
@section('panel')
@include('partials.flash')

<div x-data="stockPage(@js($items), { receiveUrl: @js(route('stock.receive')), branch: @js($branchId), branchName: @js($branchName), live: true })"
     x-on:stock-receive.window="openReceive()" x-on:stock-count-sheet.window="window.print()" class="stack">

    <div class="cols-4 stagger">
        <x-card><div class="kpi-top"><span class="icon-chip"><x-icon name="stock" :size="16" /></span>Products</div>
            <div class="kpi-value" x-count.int="summary.products">{{ $items->count() }}</div><span class="delta-note">variants carried here</span></x-card>
        <x-card><div class="kpi-top"><span class="icon-chip accent"><x-icon name="alert" :size="16" /></span>Below par</div>
            <div class="kpi-value" x-count.int="summary.low">0</div><span class="delta-note">at or under the restock level</span></x-card>
        <x-card><div class="kpi-top"><span class="icon-chip"><x-icon name="x" :size="16" /></span>Out of stock</div>
            <div class="kpi-value" :style="summary.out && 'color:var(--bad)'" x-count.int="summary.out">0</div><span class="delta-note">nothing left to sell</span></x-card>
        <x-card><div class="kpi-top"><span class="icon-chip"><x-icon name="coins" :size="16" /></span>Stock value</div>
            <div class="kpi-value" x-count.peso.compact="summary.value">₱0</div><span class="delta-note">on hand × selling price</span></x-card>
    </div>

    <x-card flush>
        <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center;justify-content:space-between;padding:14px 16px;border-bottom:1px solid var(--line)">
            <x-segmented :options="['all' => 'All', 'low' => 'Running low', 'out' => 'Out of stock']" model="tab" light label="Stock filter" />
            <div style="display:flex;gap:8px;flex-wrap:wrap">
                @if (count($branches) > 1)
                    <form method="GET"><select class="select" name="branch" onchange="this.form.submit()" aria-label="Branch" style="width:auto;height:34px">
                        @foreach ($branches as $b)<option value="{{ $b['id'] }}" @selected($branchId === $b['id'])>{{ $b['name'] }}</option>@endforeach
                    </select></form>
                @endif
                <select class="select" x-model="category" aria-label="Category" style="width:auto;height:34px" x-show="categories.length">
                    <option value="">All categories</option>
                    <template x-for="c in categories" :key="c"><option :value="c" x-text="c"></option></template>
                </select>
                <label class="input-icon" style="min-width:200px"><span class="sr-only">Search products</span><x-icon name="search" :size="15" />
                    <input class="input" style="height:34px" type="search" x-model="q" placeholder="Product or SKU  /" data-page-search></label>
                <button type="button" class="btn sm" style="height:34px" x-on:click="csv()"><x-icon name="download" :size="15" /> CSV</button>
            </div>
        </div>
        <x-table stack>
            <x-slot:head><th>Product</th><th>SKU</th><th>Category</th><th style="min-width:220px">Level</th><th>Status</th><th></th></x-slot:head>
            <template x-for="i in filtered" :key="i.variant_id">
                <tr :style="flash === i.variant_id && 'background:var(--accent-soft)'">
                    <td><span class="cell-strong" x-text="i.product"></span><div class="cell-sub" x-text="i.variant + (i.batched !== i.qty ? ' · ' + i.batched + ' in batches' : '')"></div></td>
                    <td data-label="SKU" class="cell-sub" x-text="i.sku || '—'"></td>
                    <td data-label="Category" x-text="i.category || '—'"></td>
                    <td><div style="display:flex;align-items:center;gap:10px">
                        <x-progress-bar x-width="width(i)" x-tick="tick(i)" style="flex:1" ::class="i.qty <= 0 ? 'bad' : ''" label="Stock level" />
                        <span class="num" style="white-space:nowrap;font-size:12.5px;min-width:78px;text-align:right"><b x-text="i.qty"></b><span class="muted" x-text="' / ' + (i.threshold ?? 'not set')"></span></span></div></td>
                    <td><span class="badge" :class="state(i)[0]" x-text="state(i)[1]"></span></td>
                    <td class="r"><button type="button" class="btn sm" x-on:click="openReceive(i.variant_id)" :aria-label="'Receive ' + i.product">Receive</button></td>
                </tr>
            </template>
            <tr x-show="!filtered.length"><td colspan="6" class="empty">Nothing matches.</td></tr>
        </x-table>
        <noscript>
            <table class="table"><thead><tr><th>Product</th><th>Variant</th><th>In stock</th><th>Restock at</th></tr></thead><tbody>
            @foreach ($inventory['items'] ?? [] as $i)<tr><td>{{ $i['product_name'] }}</td><td>{{ $i['variant_label'] ?: 'Regular' }}</td><td><strong>{{ $i['quantity'] }}</strong></td><td>{{ $i['restock_threshold'] ?? 'Not set' }}</td></tr>@endforeach
            </tbody></table>
        </noscript>
    </x-card>
    <p class="note" style="margin:0">Receiving adds a batch through the app's own receiving function (first-expiry-first-out). Adjustments and transfers are done in the app; every change appears under Recent stock changes.</p>

    {{-- Receive stock --}}
    <x-modal name="receive-stock" title="Receive stock">
        <form x-on:submit.prevent="receive()">
            <div class="modal-body form-grid">
                <div><label class="form-label" for="rs-product">Product</label>
                    <select id="rs-product" class="select" x-model="form.variant_id" required>
                        <option value="">Choose a product</option>
                        <template x-for="i in items" :key="i.variant_id"><option :value="i.variant_id" x-text="i.product + (i.variant !== 'Regular' ? ' · ' + i.variant : '') + ' (' + i.qty + ' on hand)'"></option></template>
                    </select></div>
                <div class="form-grid two">
                    <div><label class="form-label" for="rs-qty">Quantity received</label>
                        <input id="rs-qty" class="input" type="number" min="1" max="100000" x-model="form.quantity" required></div>
                    <div><label class="form-label" for="rs-exp">Expiration date</label>
                        <input id="rs-exp" class="input" type="date" x-model="form.expiration_date" :min="new Date(Date.now() + 864e5).toISOString().slice(0, 10)" required></div>
                </div>
                <div><label class="form-label" for="rs-code">Batch code</label>
                    <input id="rs-code" class="input" maxlength="40" x-model="form.batch_code" required>
                    <p class="form-hint">Printed on the supplier's pack, or your own code. The app tracks batches first-expiry-first-out.</p></div>
                <p class="form-error" x-show="formError" x-text="formError" role="alert"></p>
            </div>
            <div class="modal-foot">
                <button type="button" class="btn" x-on:click="$dispatch('close-modal', 'receive-stock')">Cancel</button>
                <button type="submit" class="btn primary" :class="busy && 'is-busy'">Receive</button>
            </div>
        </form>
    </x-modal>
</div>

@if (count($overview) > 1)
<div class="section-title"><h2>All branches</h2><p>Every branch you can see, at a glance</p></div>
<x-card flush data-inventory-overview>
    <x-table>
        <x-slot:head><th>Branch</th><th class="r">Products carried</th><th class="r">Units in stock</th><th>Running low</th><th>Out of stock</th><th></th></x-slot:head>
        @foreach ($overview as $o)
            <tr><td class="cell-strong">{{ $o['name'] }}</td><td class="r num">{{ $o['items'] }}</td><td class="r num">{{ number_format($o['units']) }}</td>
                <td>@if ($o['low'])<x-badge tone="warn">{{ $o['low'] }}</x-badge>@else <span class="muted">0</span> @endif</td>
                <td>@if ($o['out'])<x-badge tone="bad">{{ $o['out'] }}</x-badge>@else <span class="muted">0</span> @endif</td>
                <td class="r"><a class="link" href="?branch={{ $o['id'] }}">{{ $o['id'] === $branchId ? 'Shown above' : 'Open' }}</a></td></tr>
        @endforeach
    </x-table>
</x-card>
@endif

<div class="section-title"><h2>Reorder suggestions</h2>
    <p>Demand over {{ $reorder['lookback_days'] ?? 28 }} days ({{ $reorder['open_days'] ?? 0 }} with sales) · lead time {{ $reorder['lead_time_days'] ?? 7 }} + {{ $reorder['safety_days'] ?? 3 }} safety days · cover {{ $reorder['cover_days'] ?? 14 }} days</p></div>
<x-card flush>
    <x-table>
        <x-slot:head><th>Product</th><th class="r">On hand</th><th class="r">Usable</th><th class="r">Avg. per day</th><th class="r">Days left</th><th class="r">Reorder at</th><th>Suggested order</th></x-slot:head>
        @forelse (collect($reorder['items'] ?? [])->filter(fn ($i) => $i['avg_daily_demand'] > 0) as $i)
            <tr><td class="cell-strong">{{ $i['product'] }}{{ in_array($i['variant'], ['', 'Regular'], true) ? '' : ' · '.$i['variant'] }}</td>
                <td class="r num">{{ $i['on_hand'] }}</td><td class="r num">{{ $i['usable'] }}{{ $i['expiring_within_lead_time'] ? ' ('.$i['expiring_within_lead_time'].' expiring)' : '' }}</td>
                <td class="r num">{{ $i['avg_daily_demand'] }}</td><td class="r num">{{ $i['days_of_cover'] ?? '—' }}</td><td class="r num">{{ $i['reorder_point'] }}</td>
                <td>@if ($i['needs_reorder'])<x-badge tone="bad">Order {{ $i['suggested_quantity'] }}</x-badge>@else <x-badge tone="ok">OK</x-badge>@endif</td></tr>
        @empty
            <tr><td colspan="7" class="empty">No sales in the look-back period, so there is nothing to base a suggestion on.</td></tr>
        @endforelse
    </x-table>
</x-card>
<p class="note" style="margin:0">Units in batches that expire before new stock would arrive are not counted as usable.</p>

<div class="section-title"><h2>Expiring within 30 days</h2></div>
<x-card flush>
    <x-table>
        <x-slot:head><th>Batch</th><th>Product</th><th class="r">Units</th><th>Expires</th><th></th></x-slot:head>
        @forelse ($expiring as $b)
            <tr><td class="cell-strong">{{ $b['batch_code'] }}</td><td>{{ $b['product'] }}{{ in_array($b['variant'], ['', 'Regular'], true) ? '' : ' · '.$b['variant'] }}</td>
                <td class="r num">{{ $b['quantity'] }}</td><td>{{ \Carbon\Carbon::parse($b['expiration_date'])->format('M j, Y') }}</td>
                <td><x-badge :tone="$b['expired'] ? 'bad' : ($b['days_left'] <= 7 ? 'warn' : 'info')">{{ $b['expired'] ? 'Expired' : $b['days_left'].' days left' }}</x-badge></td></tr>
        @empty
            <tr><td colspan="5" class="empty">Nothing expires in the next 30 days.</td></tr>
        @endforelse
    </x-table>
</x-card>

<div class="section-title"><h2>Recent stock changes</h2></div>
<x-card flush>
    <x-table>
        <x-slot:head><th>When</th><th>Product</th><th class="r">Change</th><th>Type</th><th>Reason / reference</th><th>By</th></x-slot:head>
        @forelse ($movements as $m)
            <tr><td class="cell-sub" style="white-space:nowrap">{{ \Carbon\Carbon::parse($m['created_at'])->setTimezone(config('app.timezone'))->format('M j, g:i A') }}</td>
                <td>{{ $m['product_name'] ?? '—' }}{{ ($m['variant_label'] ?? '') && $m['variant_label'] !== 'Regular' ? ' ('.$m['variant_label'].')' : '' }}</td>
                <td class="r num"><strong style="color:{{ $m['quantity_change'] > 0 ? 'var(--ok)' : 'var(--ink)' }}">{{ $m['quantity_change'] > 0 ? '+' : '' }}{{ $m['quantity_change'] }}</strong></td>
                <td style="text-transform:capitalize">{{ str_replace('_', ' ', $m['movement_type']) }}</td>
                <td class="cell-sub">{{ $m['reason'] ?: '' }} {{ $m['reference'] ? '· '.$m['reference'] : '' }}</td>
                <td>@if ($m['staff_name'] ?? null)<span class="who"><span class="avatar sm">{{ mb_strtoupper(mb_substr($m['staff_name'], 0, 1)) }}</span>{{ $m['staff_name'] }}</span>@else — @endif</td></tr>
        @empty
            <tr><td colspan="6" class="empty">No stock changes recorded yet.</td></tr>
        @endforelse
    </x-table>
</x-card>

{{-- Count-sheet print styles: resources/css/melai.css (@media print). --}}
@endsection
