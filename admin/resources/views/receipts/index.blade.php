@extends('layouts.panel')
@section('title', 'Receiving · Melai Nuts Admin')
@section('page-title', 'Receiving — supplier invoices (OCR)')
@section('panel')
@include('partials.flash')
@php $peso = fn ($n) => '₱'.number_format((float) $n, 2); $tone = ['draft' => 'average', 'approved' => 'high', 'cancelled' => 'info']; @endphp

<div style="display:flex;gap:.6rem;flex-wrap:wrap">
    <a class="btn-solid" style="padding:.5rem 1.2rem;width:fit-content" href="{{ route('receipts.create') }}">+ Scan a supplier invoice</a>
    <a class="btn-outline" style="padding:.5rem 1.2rem;width:fit-content" href="{{ route('suppliers.index') }}">Suppliers</a>
</div>
<p class="muted">Take a photo of the supplier's invoice. OCR reads it into a draft; you check each line against the paper and approve. Stock is added only when a receipt is approved, and the same invoice can never be added twice.</p>

<form method="GET" class="card" style="max-width:none;display:flex;flex-wrap:wrap;gap:1rem;align-items:end">
    @if ($isOwner)
    <div><label for="branch"><strong>Branch</strong></label><br>
        <select class="light-input" id="branch" name="branch"><option value="">All branches</option>
            @foreach ($branches as $b)<option value="{{ $b['id'] }}" @selected($branch === $b['id'])>{{ $b['name'] }}</option>@endforeach</select></div>
    @endif
    <div><label for="status"><strong>Status</strong></label><br>
        <select class="light-input" id="status" name="status"><option value="">All</option>
            @foreach (['draft' => 'Drafts (to review)', 'approved' => 'Approved', 'cancelled' => 'Cancelled'] as $k => $v)<option value="{{ $k }}" @selected($status === $k)>{{ $v }}</option>@endforeach</select></div>
    <div><button class="btn-solid" style="padding:.5rem 1.2rem" type="submit">Show</button></div>
</form>

<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Receipt</th><th>Status</th><th>Branch</th><th>Supplier</th><th>Invoice no.</th><th>Invoice date</th><th>Lines</th><th>Total</th><th></th></tr></thead>
        <tbody>
        @forelse ($receipts as $r)
            <tr>
                <td><strong>{{ $r['receipt_code'] }}</strong> @if ($r['source'] === 'ocr')<span class="muted">· OCR</span>@endif</td>
                <td><span class="status {{ $tone[$r['status']] ?? 'info' }}">{{ ucfirst($r['status']) }}</span></td>
                <td>{{ $r['branch_name'] }}</td><td>{{ $r['supplier_name'] ?? '—' }}</td><td>{{ $r['supplier_invoice_no'] ?? '—' }}</td>
                <td>{{ $r['invoice_date'] ?? '—' }}</td><td>{{ $r['lines'] }}</td><td>{{ $peso($r['total']) }}</td>
                <td><a class="btn-outline" style="padding:.25rem .8rem" href="{{ route('receipts.show', $r['id']) }}">{{ $r['status'] === 'draft' ? 'Review' : 'View' }}</a></td>
            </tr>
        @empty
            <tr><td colspan="9">No receipts yet.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
@endsection
