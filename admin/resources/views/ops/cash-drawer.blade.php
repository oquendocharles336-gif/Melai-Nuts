@extends('layouts.panel')
@section('title', 'Cash Drawer · Melai Nuts Admin')
@section('page-title', 'Cash Drawer')
@section('panel')
@php $t = $summary['totals'] ?? []; @endphp
@include('partials.flash')

<form method="GET" class="card" style="max-width:none;display:flex;flex-wrap:wrap;gap:1rem;align-items:end">
    <div><label for="branch"><strong>Branch</strong></label><br>
        <select class="light-input" id="branch" name="branch">@if ($allowAll)<option value="" @selected(! $branchId)>All branches</option>@endif
            @foreach ($branches as $b)<option value="{{ $b['id'] }}" @selected($branchId === $b['id'])>{{ $b['name'] }}</option>@endforeach</select></div>
    <div><label for="date"><strong>Day</strong></label><br><input class="light-input" type="date" id="date" name="date" value="{{ $date }}"></div>
    <div><button class="btn-solid" style="padding:.5rem 1.2rem" type="submit">Show</button></div>
</form>
<p class="muted">{{ $branchId ? '' : 'All branches added up. ' }}In-store (POS) sales from the app. Net = gross − discounts − completed refunds; a refund counts against the cashier who made the sale, on the day it was completed (the same rule as the dashboard and reports). Cash refunds paid out of a drawer lower that shift's expected cash. Cashiers open and close their drawer in the app; voids and counter returns are made there too and are recorded here.</p>

<section class="stat-row">
    <div class="stat"><span>Transactions</span><strong>{{ $t['transaction_count'] ?? 0 }}</strong></div>
    <div class="stat"><span>Gross sales</span><strong>{{ $peso($t['gross_sales'] ?? 0) }}</strong></div>
    <div class="stat"><span>Discounts</span><strong>{{ $peso($t['discounts'] ?? 0) }}</strong></div>
    <div class="stat"><span>Refunds and voids · {{ $t['void_count'] ?? 0 }} void(s)</span><strong>{{ $peso($t['refunds'] ?? 0) }}</strong></div>
    <div class="stat"><span>Net sales</span><strong>{{ $peso($t['net_sales'] ?? 0) }}</strong></div>
    <div class="stat"><span>Cash / non-cash</span><strong style="font-size:1.2rem">{{ $peso($t['cash_sales'] ?? 0) }} / {{ $peso($t['non_cash_sales'] ?? 0) }}</strong></div>
</section>

<div class="block-head"><h2>By cashier</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Cashier</th>@if (! $branchId)<th>Branch</th>@endif<th>Transactions</th><th>Gross</th><th>Discounts</th><th>Refunds</th><th>Voids</th><th>Net</th><th>Cash</th><th>Non-cash</th></tr></thead>
        <tbody>
        @forelse ($summary['cashiers'] ?? [] as $c)
            <tr><td>{{ $c['staff_name'] }}</td>@if (! $branchId)<td>{{ $c['branch_name'] ?? '—' }}</td>@endif<td>{{ $c['transaction_count'] }}</td><td>{{ $peso($c['gross_sales']) }}</td><td>{{ $peso($c['discounts'] ?? null) }}</td><td>{{ $peso($c['refunds']) }}</td>
                <td>{{ $c['void_count'] }}</td><td><strong>{{ $peso($c['net_sales']) }}</strong></td><td>{{ $peso($c['cash_sales']) }}</td><td>{{ $peso($c['non_cash_sales']) }}</td></tr>
        @empty
            <tr><td colspan="10">No in-store sales on this day.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>

<div class="block-head"><h2>Shifts</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Shift</th><th>Cashier</th>@if (! $branchId)<th>Branch</th>@endif<th>Opened</th><th>Closed</th><th>Opening cash</th><th>Expected cash</th><th>Counted</th><th>Difference</th><th>Notes</th></tr></thead>
        <tbody>
        @forelse ($summary['shifts'] ?? [] as $s)
            @php $diff = $s['cash_difference']; @endphp
            <tr><td>{{ $s['session_id'] }}</td><td>{{ $s['staff_name'] }}</td>@if (! $branchId)<td>{{ $s['branch_name'] ?? '—' }}</td>@endif
                <td>{{ \Carbon\Carbon::parse($s['opened_at'])->setTimezone(config('app.timezone'))->format('g:i A') }}</td>
                <td>{{ $s['closed_at'] ? \Carbon\Carbon::parse($s['closed_at'])->setTimezone(config('app.timezone'))->format('g:i A') : 'open' }}</td>
                <td>{{ $peso($s['opening_cash']) }}</td><td>{{ $peso($s['expected_cash']) }}</td><td>{{ $peso($s['counted_cash']) }}</td>
                <td>@if ($diff === null) — @else <span class="status {{ (float) $diff == 0 ? 'high' : 'low' }}">{{ $peso($diff) }}</span> @endif</td>
                <td class="muted">{{ $s['closing_notes'] ?? '' }}</td></tr>
        @empty
            <tr><td colspan="10">No shifts opened on this day.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
@endsection
