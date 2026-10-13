@extends('layouts.panel')
@section('title', 'Profit & stock value · Melai Nuts Admin')
@section('page-title', 'Profit & stock value')
@section('page-sub', 'Verified sales minus refunds and discounts, against each option\'s current cost. Options without a cost are "Not set", never zero.')
@php
    $peso = fn ($n) => \App\Support\Format::peso($n, 2, 'Not set');   // here an unknown cost means "not set yet"
    $q = ['from' => $from, 'to' => $to, 'branch' => $branchId];
    $t = $profit['totals'] ?? [];
    $vt = $valuation['totals'] ?? [];
@endphp
@section('page-actions')
    <button type="button" class="btn" x-data x-on:click="window.print()"><x-icon name="printer" :size="14" /> Print / Save as PDF</button>
@endsection
@section('panel')
@include('partials.flash')

<form method="GET" action="{{ route('admin.profit.index') }}" class="chips" style="gap:8px;flex-wrap:wrap;margin-bottom:12px">
    <label>From <input class="light-input" type="date" name="from" value="{{ $from }}"></label>
    <label>To <input class="light-input" type="date" name="to" value="{{ $to }}"></label>
    <label>Branch
        <select class="light-input" name="branch">
            <option value="">All branches</option>
            @foreach ($branches as $b)
                <option value="{{ $b['id'] }}" @selected($branchId === $b['id'])>{{ $b['name'] }}</option>
            @endforeach
        </select>
    </label>
    <button class="btn sm" type="submit">Show</button>
</form>

@if ($loadError)
    <div class="flash bad" role="alert"><x-icon name="alert" :size="16" />The report could not be read: {{ $loadError }}
        (run <code>supabase/migrations/20261024000000_owner_reports.sql</code> if it is missing).</div>
@else
<x-card title="Profit by product option" :subtitle="\Carbon\Carbon::parse($from)->format('M j').' – '.\Carbon\Carbon::parse($to)->format('M j, Y')">
    <div class="setting-row"><div><b>Net sales</b><span>{{ $peso($t['net_sales'] ?? 0) }}</span></div></div>
    <div class="setting-row"><div><b>Cost of goods (options with a cost)</b><span>{{ $peso($t['cogs'] ?? 0) }}</span></div></div>
    <div class="setting-row"><div><b>Profit</b><span>{{ $peso($t['profit'] ?? 0) }}{{ isset($t['margin_percent']) ? ' · '.$t['margin_percent'].'% margin' : '' }}</span></div></div>
    @if (($t['options_without_cost'] ?? 0) > 0)
        <p class="note">{{ $t['options_without_cost'] }} option(s) sold without a cost entered ({{ $peso($t['net_sales_without_cost'] ?? 0) }} of sales) are not in the profit figure. Enter costs in the app's product pricing screens.</p>
    @endif
    <p class="note">Cost basis: {{ $profit['cost_basis'] ?? 'current cost' }}.</p>
    @if (empty($profit['rows']))
        <p>No verified sales in this period.</p>
    @else
    <div class="table-wrap"><table class="table">
        <thead><tr><th>Product</th><th>Option</th><th class="num">Units</th><th class="num">Net sales</th><th class="num">Unit cost</th><th class="num">Cost of goods</th><th class="num">Profit</th><th class="num">Margin</th></tr></thead>
        <tbody>
        @foreach ($profit['rows'] as $r)
            <tr><td>{{ $r['product'] }}</td><td>{{ $r['variant'] }}</td><td class="num">{{ $r['net_units'] }}</td><td class="num">{{ $peso($r['net_sales']) }}</td>
                <td class="num">{{ $peso($r['unit_cost']) }}</td><td class="num">{{ $peso($r['cogs']) }}</td><td class="num">{{ $peso($r['profit']) }}</td>
                <td class="num">{{ $r['margin_percent'] === null ? '—' : $r['margin_percent'].'%' }}</td></tr>
        @endforeach
        </tbody>
    </table></div>
    @endif
    <p class="page-actions"><a class="btn sm" href="{{ route('admin.profit.export', ['section' => 'profit'] + $q) }}"><x-icon name="download" :size="14" /> CSV</a></p>
</x-card>

<x-card title="Inventory value" subtitle="Stock on hand now × current cost">
    <div class="setting-row"><div><b>Value at cost</b><span>{{ $peso($vt['value'] ?? 0) }} ({{ number_format($vt['units'] ?? 0) }} units)</span></div></div>
    @if (($vt['units_without_cost'] ?? 0) > 0)
        <p class="note">{{ number_format($vt['units_without_cost']) }} unit(s) in {{ $vt['options_without_cost'] }} option(s) have no cost entered and are not valued.</p>
    @endif
    @if (empty($valuation['rows']))
        <p>No stock on hand.</p>
    @else
    <div class="table-wrap"><table class="table">
        <thead><tr><th>Branch</th><th>Product</th><th>Option</th><th class="num">On hand</th><th class="num">Unit cost</th><th class="num">Value</th></tr></thead>
        <tbody>
        @foreach ($valuation['rows'] as $r)
            <tr><td>{{ $r['branch'] }}{{ ($r['is_warehouse'] ?? false) ? ' (warehouse)' : '' }}</td><td>{{ $r['product'] }}</td><td>{{ $r['variant'] }}</td>
                <td class="num">{{ number_format($r['quantity']) }}</td><td class="num">{{ $peso($r['unit_cost']) }}</td><td class="num">{{ $peso($r['value']) }}</td></tr>
        @endforeach
        </tbody>
    </table></div>
    @endif
    <p class="page-actions"><a class="btn sm" href="{{ route('admin.profit.export', ['section' => 'valuation'] + $q) }}"><x-icon name="download" :size="14" /> CSV</a></p>
</x-card>
@endif
@endsection
