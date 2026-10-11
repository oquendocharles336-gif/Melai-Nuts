@extends('layouts.panel')
@section('title', 'Reports · Melai Nuts Admin')
@section('page-title', 'Reports')
@php
    $peso = fn ($n) => $n === null ? '—' : '₱'.number_format((float) $n, 2);
    $pct = fn ($n) => $n === null ? '—' : number_format((float) $n * 100, 1).'%';
    $s = $report['summary'] ?? [];
    $ps = $previous['summary'] ?? null;
    $q = ['from' => $from, 'to' => $to, 'branch' => $branchId];
    $days = \Carbon\Carbon::parse($from)->diffInDays(\Carbon\Carbon::parse($to)) + 1;
    $change = fn ($cur, $prev) => ($prev === null || (float) $prev == 0.0) ? null : round(((float) $cur - (float) $prev) / abs((float) $prev) * 100, 1);

    // Bars: weekly buckets (daily when the range is two weeks or less), this period vs the one before.
    $size = $days <= 14 ? 1 : 7;
    $bucket = function (array $byDay, string $start) use ($size, $days) {
        $out = array_fill(0, (int) ceil($days / $size), 0.0);
        foreach ($byDay as $d) {
            $i = (int) floor(\Carbon\Carbon::parse($start)->diffInDays(\Carbon\Carbon::parse($d['date'])) / $size);
            if ($i >= 0 && $i < count($out)) { $out[$i] += (float) $d['net_sales']; }
        }
        return $out;
    };
    $cur = $bucket($report['by_day'] ?? [], $from);
    $prevFrom = \Carbon\Carbon::parse($from)->subDays($days)->toDateString();
    $prev = $previous ? $bucket($previous['by_day'] ?? [], $prevFrom) : null;
    $bars = collect($cur)->map(fn ($v, $i) => [
        'label' => \Carbon\Carbon::parse($from)->addDays($i * $size)->format('M j'),
        'cur' => round($v, 2), 'prev' => $prev === null ? null : round($prev[$i] ?? 0, 2),
    ])->values()->all();
    $compare = [
        ['Net sales', $s['net_sales'] ?? 0, $ps['net_sales'] ?? null, 'peso'],
        ['Gross sales', $s['gross_sales'] ?? 0, $ps['gross_sales'] ?? null, 'peso'],
        ['Verified orders', $s['verified_orders'] ?? 0, $ps['verified_orders'] ?? null, 'int'],
        ['Average order value', $s['average_order_value'] ?? null, $ps['average_order_value'] ?? null, 'peso'],
        ['Refunds', $s['refunds'] ?? 0, $ps['refunds'] ?? null, 'peso', true],
        ['Discounts', $s['discounts'] ?? 0, $ps['discounts'] ?? null, 'peso', true],
    ];
    $fmt = fn ($v, $t) => $v === null ? '—' : ($t === 'peso' ? $peso($v) : number_format((float) $v));
@endphp
@section('page-sub', \Carbon\Carbon::parse($from)->format('M j').' – '.\Carbon\Carbon::parse($to)->format('M j, Y').' · '.($branchId ? (collect($branches)->firstWhere('id', $branchId)['name'] ?? '') : 'all branches').' · verified sales only')
@section('page-actions')
    <x-button icon="download" :href="route('reports.export', $q + ['section' => 'summary'])">Export summary</x-button>
@endsection
@section('panel')
@include('partials.flash')

<x-card>
    <form method="GET" style="display:flex;flex-wrap:wrap;gap:12px;align-items:end">
        <div><label class="form-label" for="from">From</label><input class="input" type="date" id="from" name="from" value="{{ $from }}" max="{{ $to }}"></div>
        <div><label class="form-label" for="to">To</label><input class="input" type="date" id="to" name="to" value="{{ $to }}"></div>
        @if ($isOwner)
            <div><label class="form-label" for="branch">Branch</label>
                <select class="select" id="branch" name="branch">
                    <option value="">All branches</option>
                    @foreach ($branches as $b) <option value="{{ $b['id'] }}" @selected($branchId === $b['id'])>{{ $b['name'] }}</option> @endforeach
                </select></div>
        @endif
        <button class="btn primary" type="submit">Apply</button>
        <div class="seg" style="margin-left:auto">
            @foreach ([7 => '7 days', 30 => '30 days', 90 => '90 days', 365 => '1 year'] as $d => $lbl)
                @php $f = now('Asia/Manila')->subDays($d - 1)->toDateString(); @endphp
                <a class="{{ $from === $f && $to === now('Asia/Manila')->toDateString() ? 'is-on' : '' }}" href="?{{ http_build_query(['from' => $f, 'to' => now('Asia/Manila')->toDateString(), 'branch' => $branchId]) }}">{{ $lbl }}</a>
            @endforeach
        </div>
    </form>
</x-card>

<div class="cols-4 stagger">
    <x-kpi label="Net sales" icon="coins" :value="$peso($s['net_sales'] ?? 0)" :delta="$change($s['net_sales'] ?? 0, $ps['net_sales'] ?? null)" delta-note="vs before" />
    <x-kpi label="Gross sales" icon="reports" :value="$peso($s['gross_sales'] ?? 0)" :delta="$change($s['gross_sales'] ?? 0, $ps['gross_sales'] ?? null)" delta-note="vs before" />
    <x-kpi label="Verified orders" icon="orders" :value="number_format($s['verified_orders'] ?? 0)" :delta="$change($s['verified_orders'] ?? 0, $ps['verified_orders'] ?? null)" delta-note="vs before">
        <span class="delta-note">{{ $s['pos_orders'] ?? 0 }} in-store · {{ $s['online_orders'] ?? 0 }} online</span></x-kpi>
    <x-kpi label="Average order value" icon="wallet" :value="$peso($s['average_order_value'] ?? null)" :delta="$change($s['average_order_value'] ?? null, $ps['average_order_value'] ?? null)" delta-note="vs before" />
</div>

<div class="ov-top">
    <x-card :title="($size === 7 ? 'Weekly' : 'Daily').' revenue'" subtitle="Net sales per {{ $size === 7 ? 'week' : 'day' }}, this period against the {{ $days }} days before">
        <div x-data="{ weekly: @js($bars) }"><x-chart-bars data="weekly" :height="270" label="Revenue per {{ $size === 7 ? 'week' : 'day' }}" cur-label="This period" prev-label="{{ $previous ? 'Previous '.$days.' days' : 'Previous period (not available)' }}" /></div>
    </x-card>
    <x-card title="Compared with before" :subtitle="$previous ? \Carbon\Carbon::parse($prevFrom)->format('M j').' – '.\Carbon\Carbon::parse($from)->subDay()->format('M j') : 'The previous period could not be read'">
        <div class="grid" style="gap:0">
            @foreach ($compare as $row)
                @php [$name, $c, $p, $t] = $row; $inverse = $row[4] ?? false; $ch = $change($c, $p); @endphp
                <div class="setting-row" style="padding:11px 0">
                    <div><b style="font-weight:550">{{ $name }}</b><span class="tabular">{{ $fmt($p, $t) }} → {{ $fmt($c, $t) }}</span></div>
                    @if ($ch === null)<span class="delta flat">—</span>
                    @else<span class="delta {{ ($ch > 0) !== $inverse ? ($ch == 0 ? 'flat' : 'up') : 'down' }}">{{ $ch > 0 ? '↑' : ($ch < 0 ? '↓' : '') }} {{ number_format(abs($ch), 1) }}%</span>@endif
                </div>
            @endforeach
        </div>
    </x-card>
</div>

<section class="stat-row">
    <div class="stat"><span>Gross sales</span><strong>{{ $peso($s['gross_sales'] ?? 0) }}</strong></div>
    <div class="stat"><span>Discounts</span><strong>{{ $peso($s['discounts'] ?? 0) }}</strong></div>
    <div class="stat"><span>Refunds ({{ $s['refund_count'] ?? 0 }})</span><strong>{{ $peso($s['refunds'] ?? 0) }}</strong></div>
    <div class="stat"><span>Revenue (net + delivery fees)</span><strong>{{ $peso($s['revenue'] ?? 0) }}</strong></div>
    <div class="stat"><span>Refund rate</span><strong>{{ $pct($s['refund_rate'] ?? null) }}</strong><span>{{ $s['voids'] ?? 0 }} POS voids</span></div>
    <div class="stat"><span>Pending refunds (not deducted)</span><strong>{{ $peso($s['pending_refunds']['amount'] ?? null) }}</strong>
        <span>{{ $s['pending_refunds']['count'] ?? '—' }} open now</span></div>
    <div class="stat"><span>Pending payments (not counted)</span><strong>{{ $peso($s['pending_payments']['amount'] ?? 0) }}</strong>
        <span>{{ $s['pending_payments']['count'] ?? 0 }} orders</span></div>
    <div class="stat"><span>Deliveries</span><strong>{{ $s['completed_deliveries'] ?? 0 }}</strong>
        <span>{{ $s['failed_deliveries'] ?? 0 }} failed · {{ $s['cancelled_orders'] ?? 0 }} orders cancelled</span></div>
</section>

<details class="card" style="max-width:none">
    <summary><strong>How these numbers are calculated</strong></summary>
    <ul class="muted">@foreach ($report['definitions'] ?? [] as $k => $v)<li><strong>{{ str_replace('_', ' ', $k) }}</strong>: {{ $v }}</li>@endforeach</ul>
</details>

<x-card title="Download CSV" subtitle="Same numbers, same filters">
    <div style="display:flex;flex-wrap:wrap;gap:8px">
        <a class="btn sm" href="{{ route('reports.export', $q + ['section' => 'summary']) }}"><x-icon name="download" :size="14" /> Summary</a>
        @foreach ($csv as $key => $label)
            <a class="btn sm" href="{{ route('reports.export', $q + ['section' => $key]) }}"><x-icon name="download" :size="14" /> {{ ucfirst(str_replace('-', ' ', $label)) }}</a>
        @endforeach
    </div>
</x-card>

<div class="cols-3">
    <x-card title="By branch" flush><x-table>
        <x-slot:head><th>Branch</th><th class="r">Orders</th><th class="r">Gross</th><th class="r">Refunds</th><th class="r">Net</th><th class="r">Rate</th></x-slot:head>
        @forelse ($report['by_branch'] ?? [] as $b)
            <tr><td>{{ $b['branch'] ?? '—' }}</td><td class="r num">{{ $b['orders'] }}</td><td class="r num">{{ $peso($b['gross_sales']) }}</td>
                <td class="r num">{{ $peso($b['refunds'] ?? null) }}</td><td class="r num"><strong>{{ $peso($b['net_sales']) }}</strong></td><td class="r num">{{ $pct($b['refund_rate'] ?? null) }}</td></tr>
        @empty <tr><td colspan="6" class="empty">No branches.</td></tr> @endforelse
    </x-table></x-card>
    <x-card title="Payment methods" subtitle="Net = after discounts and refunds" flush><x-table>
        <x-slot:head><th>Method</th><th class="r">Orders</th><th class="r">Refunds</th><th class="r">Net</th></x-slot:head>
        @forelse ($report['by_payment_method'] ?? [] as $m)
            <tr><td>{{ strtoupper($m['method']) }}</td><td class="r num">{{ $m['orders'] }}</td><td class="r num">{{ $peso($m['refunds'] ?? null) }}</td><td class="r num">{{ $peso($m['net_sales'] ?? null) }}</td></tr>
        @empty <tr><td colspan="4" class="empty">No verified payments.</td></tr> @endforelse
    </x-table></x-card>
    <x-card title="By category" subtitle="Units net of refunded units" flush><x-table>
        <x-slot:head><th>Category</th><th class="r">Units</th><th class="r">Refunds</th><th class="r">Net</th></x-slot:head>
        @forelse ($report['by_category'] ?? [] as $c)
            <tr><td>{{ $c['category'] }}</td><td class="r num">{{ $c['units'] }}</td><td class="r num">{{ $peso($c['refunds'] ?? null) }}</td><td class="r num">{{ $peso($c['net_sales'] ?? null) }}</td></tr>
        @empty <tr><td colspan="4" class="empty">No sales.</td></tr> @endforelse
    </x-table></x-card>
</div>

<div class="cols-2">
    <x-card title="Best sellers" subtitle="By net sales; units net of refunded units" flush><x-table>
        <x-slot:head><th>Product</th><th class="r">Units</th><th class="r">Refunded</th><th class="r">Net</th></x-slot:head>
        @forelse ($report['top_products'] ?? [] as $p)
            <tr><td>{{ $p['product'] }}{{ in_array($p['variant'], ['', 'Regular'], true) ? '' : ' · '.$p['variant'] }}</td><td class="r num">{{ $p['units'] }}</td>
                <td class="r num">{{ $p['refunded_units'] ?? '—' }}</td><td class="r num">{{ $peso($p['net_sales'] ?? null) }}</td></tr>
        @empty <tr><td colspan="4" class="empty">No sales.</td></tr> @endforelse
    </x-table></x-card>
    <x-card title="Slow movers" subtitle="In stock, sold least" flush><x-table>
        <x-slot:head><th>Product</th><th class="r">In stock</th><th class="r">Sold</th></x-slot:head>
        @forelse ($report['slow_movers'] ?? [] as $p)
            <tr><td>{{ $p['product'] }}{{ in_array($p['variant'], ['', 'Regular'], true) ? '' : ' · '.$p['variant'] }}</td><td class="r num">{{ $p['in_stock'] }}</td><td class="r num">{{ $p['units_sold'] }}</td></tr>
        @empty <tr><td colspan="3" class="empty">Nothing in stock.</td></tr> @endforelse
    </x-table></x-card>
</div>

<div class="cols-3">
    @php $c = $report['customers'] ?? []; $l = $report['loyalty'] ?? []; $inv = $report['inventory'] ?? []; @endphp
    <x-card title="Customers">
        <div class="setting-row"><span>New sign-ups</span><b class="tabular">{{ $c['new_customers'] ?? 0 }}</b></div>
        <div class="setting-row"><span>Buying customers</span><b class="tabular">{{ $c['active_customers'] ?? 0 }}</b></div>
        <div class="setting-row"><span>Bought more than once</span><b class="tabular">{{ $c['repeat_customers'] ?? 0 }} ({{ $pct($c['repeat_rate'] ?? null) }})</b></div>
        <p class="note">Walk-in POS sales are not linked to a customer and are left out here.</p></x-card>
    <x-card title="Loyalty">
        <div class="setting-row"><span>Points earned</span><b class="tabular">{{ number_format($l['points_earned'] ?? 0) }}</b></div>
        <div class="setting-row"><span>Points used</span><b class="tabular">{{ number_format($l['points_redeemed'] ?? 0) }}</b></div>
        <div class="setting-row"><span>Points reversed by refunds</span><b class="tabular">{{ isset($l['points_reversed']) ? number_format($l['points_reversed']) : '—' }}</b></div>
        <div class="setting-row"><span>Members with activity</span><b class="tabular">{{ $l['members_active'] ?? 0 }}</b></div></x-card>
    <x-card title="Inventory now">
        <div class="setting-row"><span>Units on hand</span><b class="tabular">{{ number_format($inv['units_on_hand'] ?? 0) }}</b></div>
        <div class="setting-row"><span>Value at cost</span><b class="tabular">{{ $peso($inv['stock_value_at_cost'] ?? null) }}</b></div>
        <div class="setting-row"><span>Low / out of stock</span><b class="tabular">{{ $inv['low_stock'] ?? 0 }} / {{ $inv['out_of_stock'] ?? 0 }}</b></div>
        @if (($inv['variants_without_cost'] ?? 0) > 0)<p class="note">{{ $inv['variants_without_cost'] }} item(s) have no cost price and are not valued.</p>@endif</x-card>
</div>

<div class="section-title"><h2>Daily sales</h2></div>
@php $maxDay = max(1, collect($report['by_day'] ?? [])->max('gross_sales') ?? 0); @endphp
<x-card flush><x-table>
    <x-slot:head><th>Date</th><th style="min-width:140px"></th><th class="r">Orders</th><th class="r">Gross</th><th class="r">Discounts</th><th class="r">Refunds</th><th class="r">Net</th></x-slot:head>
    @foreach (array_reverse($report['by_day'] ?? []) as $d)
        <tr><td style="white-space:nowrap">{{ \Carbon\Carbon::parse($d['date'])->format('D, M j') }}</td>
            <td><x-progress-bar :value="$d['gross_sales']" :max="$maxDay" thin /></td>
            <td class="r num">{{ $d['orders'] }}</td><td class="r num">{{ $peso($d['gross_sales']) }}</td><td class="r num">{{ $peso($d['discounts'] ?? null) }}</td>
            <td class="r num">{{ $peso($d['refunds']) }}@if (($d['refund_count'] ?? 0) > 0) ({{ $d['refund_count'] }})@endif</td><td class="r num"><strong>{{ $peso($d['net_sales']) }}</strong></td></tr>
    @endforeach
</x-table></x-card>
<p class="note">A refund counts on the day it was completed, so a day can show refunds of earlier sales (and a negative net).</p>

@if (! empty($report['by_staff']))
<div class="section-title"><h2>Sales by cashier</h2></div>
<x-card flush><x-table>
    <x-slot:head><th>Cashier</th><th class="r">Orders</th><th class="r">Gross</th><th class="r">Discounts</th><th class="r">Refunds</th><th class="r">Net</th><th class="r">Rate</th><th class="r">Voids</th></x-slot:head>
    @foreach ($report['by_staff'] as $c)
        <tr><td>{{ $c['staff_name'] ?? 'Online orders' }}</td><td class="r num">{{ $c['orders'] }}</td><td class="r num">{{ $peso($c['gross_sales']) }}</td>
            <td class="r num">{{ $peso($c['discounts']) }}</td><td class="r num">{{ $peso($c['refunds']) }}@if ($c['refund_count'] > 0) ({{ $c['refund_count'] }})@endif</td>
            <td class="r num"><strong>{{ $peso($c['net_sales']) }}</strong></td><td class="r num">{{ $pct($c['refund_rate']) }}</td><td class="r num">{{ $c['voids'] ?? 0 }}</td></tr>
    @endforeach
</x-table></x-card>
<p class="note">Refunds of in-store sales count against the cashier who rang up the sale.</p>
@endif

@if ($staff !== null && collect($staff)->contains('activity_unavailable', true))
<p class="note">Sales per cashier need the database function owner_staff_overview: run supabase/migrations/20261013000000_admin_portal_owner_overview.sql.</p>
@elseif ($staff !== null)
<div class="section-title"><h2>Sales by staff (in-store)</h2></div>
<x-card flush><x-table>
    <x-slot:head><th>Staff</th><th>Role</th><th>Branch</th><th class="r">Transactions</th><th class="r">POS sales (after discounts)</th><th class="r">Refunds</th><th class="r">Net</th><th class="r">Shifts</th></x-slot:head>
    @forelse (collect($staff)->filter(fn ($p) => $p['pos_transactions'] > 0 || (float) $p['pos_refunds'] > 0 || $p['shifts_opened'] > 0) as $p)
        <tr><td><span class="who"><span class="avatar sm">{{ mb_strtoupper(mb_substr($p['full_name'] ?: $p['email'], 0, 1)) }}</span>{{ $p['full_name'] ?: $p['email'] }}</span></td><td>{{ ucfirst($p['role']) }}</td><td>{{ $p['branch_name'] ?? '—' }}</td><td class="r num">{{ $p['pos_transactions'] }}</td>
            <td class="r num">₱{{ number_format((float) $p['pos_sales'], 2) }}</td><td class="r num">₱{{ number_format((float) $p['pos_refunds'], 2) }}</td>
            <td class="r num"><strong>₱{{ number_format((float) $p['pos_net_sales'], 2) }}</strong></td><td class="r num">{{ $p['shifts_opened'] }}</td></tr>
    @empty
        <tr><td colspan="8" class="empty">No in-store sales by any staff account in this period.</td></tr>
    @endforelse
</x-table></x-card>
@endif

<div class="section-title"><h2>Driver performance</h2></div>
<x-card flush><x-table>
    <x-slot:head><th>Driver</th><th class="r">Runs</th><th class="r">Delivered</th><th class="r">Failed</th><th class="r">Success rate</th><th class="r">Avg. minutes pickup → delivered</th></x-slot:head>
    @forelse ($report['drivers'] ?? [] as $d)
        <tr><td>{{ $d['driver'] }}</td><td class="r num">{{ $d['runs'] }}</td><td class="r num">{{ $d['delivered'] }}</td><td class="r num">{{ $d['failed'] }}</td>
            <td class="r num">{{ $pct($d['success_rate']) }}</td><td class="r num">{{ $d['avg_minutes_pickup_to_delivered'] ?? '—' }}</td></tr>
    @empty
        <tr><td colspan="6" class="empty">No runs by registered drivers in this period.</td></tr>
    @endforelse
</x-table></x-card>
@endsection
