@extends('layouts.panel')
@section('title', 'Payments · Melai Nuts Admin')
@section('page-title', 'Payments')
@section('panel')
@php $peso = fn ($n) => '₱'.number_format($n, 2);
$methodLabel = fn ($m) => ['cod' => 'COD', 'cash' => 'Cash', 'gcash' => 'GCash', 'maya' => 'Maya', 'card' => 'Card'][$m] ?? strtoupper($m);
$branchName = fn ($o) => $o['branchName'] ?? (collect($branches)->firstWhere('id', $o['branch'])['name'] ?? '—'); @endphp

@if (session('status')) <div class="card" style="border-color:#2E7D4F;background:#f1f8f2">{{ session('status') }}</div> @endif
@if (session('error')) <div class="card" style="border-color:#C0392B;background:#fdecea">{{ session('error') }}</div> @endif
@if ($errors->any())
    <div class="card" style="border-color:#C0392B;background:#fdecea">
        <ul style="margin:0;padding-left:1.1rem">@foreach ($errors->all() as $e) <li>{{ $e }}</li> @endforeach</ul>
    </div>
@endif
<p class="muted">Live from the Melai Nuts app (last {{ config('melai.supabase.order_window_days') }} days). Customers pay in cash (online payment is off by the owner's decision); only cash can be marked paid here. Past online payments were confirmed by HitPay.</p>

<form method="GET" class="card filter-row">
    <select class="light-input" name="status" onchange="this.form.submit()">
        <option value="">All statuses</option>
        @foreach (['paid', 'pending', 'failed', 'refunded'] as $s) <option value="{{ $s }}" @selected(($filters['status'] ?? '') === $s)>{{ ucfirst($s) }}</option> @endforeach
    </select>
    <select class="light-input" name="method" onchange="this.form.submit()">
        <option value="">All methods</option>
        @foreach ($methods as $m) <option value="{{ $m }}" @selected(($filters['method'] ?? '') === $m)>{{ $methodLabel($m) }}</option> @endforeach
    </select>
    <select class="light-input" name="branch" onchange="this.form.submit()">
        <option value="">All branches</option>
        @foreach ($branches as $b) <option value="{{ $b['id'] }}" @selected(($filters['branch'] ?? '') === $b['id'])>{{ $b['name'] }}</option> @endforeach
    </select>
    <input class="light-input" type="date" name="from" value="{{ $filters['from'] ?? '' }}" onchange="this.form.submit()">
    <input class="light-input" type="date" name="to" value="{{ $filters['to'] ?? '' }}" onchange="this.form.submit()">
    <input class="light-input" type="search" name="q" value="{{ $q }}" placeholder="Order, customer, reference" aria-label="Search payments" maxlength="100">
    <button class="btn-outline" type="submit" style="padding:.5rem 1rem">Search</button>
    @if (array_filter($filters) || $q !== '') <a href="{{ route('admin.payments.index') }}" class="btn-outline" style="padding:.5rem 1rem">Clear</a> @endif
    <a class="btn-outline" style="padding:.5rem 1rem" href="{{ route('admin.payments.export', request()->only(['status', 'method', 'branch', 'from', 'to', 'q'])) }}">Download CSV</a>
</form>

<section class="stat-row" data-method-totals>
    @if ($totals === null)
        <div class="stat"><span>Totals per method need supabase/migrations/20261015000000_refunds_in_analytics.sql</span><strong>—</strong></div>
    @else
    @forelse ($totals as $m)
        <div class="stat"><span>{{ $methodLabel($m['method']) }} · net sales ({{ $m['orders'] }} orders)</span><strong>{{ $peso($m['net_sales']) }}</strong>
            <span>gross {{ $peso($m['gross_sales']) }} · refunds {{ $peso($m['refunds']) }}</span></div>
    @empty
        <div class="stat"><span>No paid orders in this period</span></div>
    @endforelse
    @endif
</section>
<p class="muted" style="margin-top:0">Totals: {{ \Carbon\Carbon::parse($totalsRange[0])->format('M j') }} – {{ \Carbon\Carbon::parse($totalsRange[1])->format('M j, Y') }}{{ ($filters['branch'] ?? null) ? ', this branch' : '' }}; net = after discounts and completed refunds, the same figures as the dashboard and reports (the status and method filters apply to the lists below).</p>

<div class="block-head"><h2>Failed / pending payments</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Order</th><th>Branch</th><th>Method</th><th>Amount</th><th>Status</th><th>Date</th><th></th></tr></thead>
        <tbody>
        @forelse ($failedOrPending as $o)
            <tr>
                <td>{{ $o['id'] }}</td><td>{{ $branchName($o) }}</td>
                <td>{{ $methodLabel($o['paymentMethod']) }}</td><td>{{ $peso($o['total']) }}</td>
                <td><span class="status {{ $o['effectivePaymentStatus'] === 'failed' ? 'low' : 'average' }}">{{ ucfirst($o['effectivePaymentStatus']) }}</span></td>
                <td>{{ $o['createdAt']->format('M j, g:i A') }}</td>
                <td>
                    @if ($o['paymentMethod'] === $cashMethod && $o['effectivePaymentStatus'] === 'pending')
                        <form method="POST" action="{{ route('admin.payments.mark-paid', $o['id']) }}" data-confirm="Mark order {{ $o['id'] }} as paid? Only do this once the cash has been collected." data-confirm-title="Mark as paid?" data-confirm-label="Mark as paid" data-confirm-safe">
                            @csrf
                            <x-password-confirm />
                            <button class="btn-outline" type="submit" style="padding:.3rem .8rem">Mark as paid</button>
                        </form>
                    @endif
                </td>
            </tr>
        @empty
            <tr><td colspan="7">Nothing failed or pending for these filters.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>

<div class="block-head"><h2>All payments</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Order</th><th>Branch</th><th>Method</th><th>Amount</th><th>Refunded</th><th>Status</th><th>Paid at</th></tr></thead>
        <tbody>
        @forelse ($orders as $o)
            <tr>
                <td>{{ $o['id'] }}</td><td>{{ $branchName($o) }}</td>
                <td>{{ $methodLabel($o['paymentMethod']) }}</td><td>{{ $peso($o['total']) }}</td>
                <td>{{ ($o['refundedAmount'] ?? null) === null ? '—' : (($o['refundedAmount'] > 0) ? $peso($o['refundedAmount']).(($o['refundState'] ?? null) === 'partial' ? ' (partial)' : '') : '—') }}</td>
                <td><span class="status {{ ['paid' => 'high', 'pending' => 'average', 'failed' => 'low', 'refunded' => 'info'][$o['effectivePaymentStatus']] ?? 'info' }}">{{ ($o['refundState'] ?? null) === 'partial' && $o['effectivePaymentStatus'] === 'refunded' ? 'Partially refunded' : ucfirst($o['effectivePaymentStatus']) }}</span></td>
                <td>{{ $o['paidAt']?->format('M j, g:i A') ?? '—' }}</td>
            </tr>
        @empty
            <tr><td colspan="7">No payments match.</td></tr>
        @endforelse
        </tbody>
    </table>
    <p class="muted">{{ $orders->total() }} match(es){{ $orders->hasPages() ? ', page '.$orders->currentPage().' of '.$orders->lastPage() : '' }}.</p>
    @if ($orders->hasPages()){{ $orders->links() }}@endif
</div>
@endsection
