@extends('layouts.panel')
@section('title', 'Sales · Melai Nuts Admin')
@section('page-title', 'Sales')
@section('panel')
@php
    $peso = fn ($n) => $n === null ? '—' : '₱'.number_format((float) $n, 2);
    $int = fn ($n) => $n === null ? '—' : number_format((int) $n);
    $rate = fn ($n) => $n === null ? '—' : number_format((float) $n * 100, 1).'%';
    $maxDay = max(1, collect($summary['daily'] ?? [])->max(fn ($d) => max(0, (float) ($d['revenue'] ?? 0))) ?? 0);
    $tot = $summary['totals']['window'] ?? null;
    $pending = $summary['totals']['pending_refunds'] ?? null;
@endphp
@include('partials.flash')

<div class="block-head">
    <h2>Sales by branch</h2>
    <div class="tabs">@foreach ([7 => '7 days', 30 => '30 days', 90 => '90 days'] as $k => $v)
        <a href="?days={{ $k }}" class="{{ $days === $k ? 'active' : '' }}">{{ $v }}</a>@endforeach</div>
</div>
<p class="muted">Net sales = orders with a confirmed payment (online, pickup and POS) − discounts − completed refunds. A refund counts on the day it was completed (partial refunds included); refunds still being reviewed are listed as pending and are not deducted. The same figures as the Melai Nuts app{{ $isOwner ? '' : ' — your branch only' }}.</p>

@if ($summary === null)
    <div class="card">Sales figures need the database function sales_overview: run supabase/migrations/20261015000000_refunds_in_analytics.sql. Nothing is shown until then (no figure is calculated here).</div>
@else
@if ($tot)
<section class="stat-row" data-sales-totals>
    <div class="stat"><span>Net sales ({{ $days }} days)</span><strong>{{ $peso($tot['net_sales']) }}</strong></div>
    <div class="stat"><span>Gross sales</span><strong>{{ $peso($tot['gross_sales']) }}</strong></div>
    <div class="stat"><span>Discounts</span><strong>{{ $peso($tot['discounts']) }}</strong></div>
    <div class="stat"><span>Refunds ({{ $int($tot['refund_count']) }})</span><strong>{{ $peso($tot['refunds']) }}</strong></div>
    <div class="stat"><span>Refund rate</span><strong>{{ $rate($tot['refund_rate']) }}</strong></div>
    <div class="stat"><span>Pending refunds (not deducted)</span><strong>{{ $peso($pending['amount'] ?? null) }}</strong><span>{{ $int($pending['count'] ?? null) }} open</span></div>
</section>
@endif

<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Branch</th><th>Today (net)</th><th>Last 7 days (net)</th><th>Gross ({{ $days }} d)</th><th>Discounts</th><th>Refunds</th><th>Net ({{ $days }} d)</th><th>Refund rate</th><th>Pending refunds</th><th>Paid orders today / {{ $days }} d</th></tr></thead>
        <tbody>
        @forelse ($summary['branches'] ?? [] as $b)
            @php $w = $b['window'] ?? null; @endphp
            <tr><td>{{ $b['name'] ?? '—' }}</td><td>{{ $peso($b['today_revenue']) }}</td><td>{{ $peso($b['week_revenue']) }}</td>
                <td>{{ $peso($w['gross_sales'] ?? null) }}</td><td>{{ $peso($w['discounts'] ?? null) }}</td>
                <td>{{ $peso($w['refunds'] ?? null) }}@if (($w['refund_count'] ?? 0) > 0) ({{ $w['refund_count'] }})@endif</td>
                <td><strong>{{ $peso($b['window_revenue']) }}</strong></td><td>{{ $rate($w['refund_rate'] ?? null) }}</td>
                <td>{{ $peso($b['pending_refund_amount'] ?? null) }}@if (($b['pending_refund_count'] ?? 0) > 0) ({{ $b['pending_refund_count'] }})@endif</td>
                <td>{{ $int($b['orders_today']) }} / {{ $int($b['orders_window']) }}</td></tr>
        @empty
            <tr><td colspan="10">No branches yet.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>

<div class="block-head"><h2>Daily net sales</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Day</th><th></th><th style="text-align:right">Gross</th><th style="text-align:right">Refunds</th><th style="text-align:right">Net</th></tr></thead>
        <tbody>
        @foreach (array_reverse($summary['daily'] ?? []) as $d)
            <tr><td style="width:8rem">{{ \Carbon\Carbon::parse($d['date'])->format('D, M j') }}</td>
                <td><div class="bar" style="margin:0"><span class="high" style="width: {{ round(max(0, (float) $d['revenue']) / $maxDay * 100) }}%"></span></div></td>
                <td style="width:7rem;text-align:right">{{ $peso($d['gross_sales'] ?? null) }}</td>
                <td style="width:7rem;text-align:right">{{ $peso($d['refunds'] ?? null) }}</td>
                <td style="width:8rem;text-align:right"><strong>{{ $peso($d['revenue']) }}</strong></td></tr>
        @endforeach
        </tbody>
    </table>
</div>

@if ($staff !== null && collect($staff)->contains('activity_unavailable', true))
<p class="muted">Sales per cashier need the database function owner_staff_overview: run supabase/migrations/20261013000000_admin_portal_owner_overview.sql.</p>
@elseif ($staff !== null)
<div class="block-head"><h2>Sales per cashier ({{ $days }} days, all branches)</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Staff</th><th>Role</th><th>Branch</th><th>POS transactions</th><th>POS sales</th><th>Refunds</th><th>Net</th><th>Refund rate</th><th>Shifts</th></tr></thead>
        <tbody>
        @forelse (collect($staff)->filter(fn ($p) => $p['pos_transactions'] > 0 || (float) $p['pos_refunds'] > 0 || $p['shifts_opened'] > 0) as $p)
            <tr><td>{{ $p['full_name'] ?: $p['email'] }}</td><td>{{ ucfirst($p['role']) }}</td><td>{{ $p['branch_name'] ?? '—' }}</td><td>{{ $p['pos_transactions'] }}</td>
                <td>{{ $peso($p['pos_sales']) }}</td><td>{{ $peso($p['pos_refunds']) }}@if (($p['pos_refund_count'] ?? 0) > 0) ({{ $p['pos_refund_count'] }})@endif</td>
                <td><strong>{{ $peso($p['pos_net_sales']) }}</strong></td><td>{{ $rate($p['pos_refund_rate'] ?? null) }}</td><td>{{ $p['shifts_opened'] }}</td></tr>
        @empty
            <tr><td colspan="9">No in-store sales by any cashier in this period.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
<p class="note">POS sales are after discounts. A refund of a POS sale counts against the cashier who made the sale, on the day it was completed.</p>
@endif

<div class="block-head"><h2>Top products ({{ $days }} days)</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Product</th><th>Net units</th><th>Refunded units</th><th>Net sales</th></tr></thead>
        <tbody>
        @forelse ($summary['products'] ?? [] as $p)
            <tr><td>{{ $p['product_name'] }}</td><td>{{ $int($p['units']) }}</td><td>{{ $int($p['refunded_units'] ?? null) }}</td><td>{{ $peso($p['revenue']) }}</td></tr>
        @empty
            <tr><td colspan="4">No sales in this period.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
<p class="note">Net units = units sold − units refunded; net sales per product = item sales − their share of discounts − refunds of that product.</p>
@endif
@endsection
