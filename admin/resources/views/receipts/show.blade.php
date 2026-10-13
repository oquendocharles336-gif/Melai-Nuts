@extends('layouts.panel')
@section('title', $r['receipt_code'].' · Receiving · Melai Nuts Admin')
@section('page-title', 'Receipt '.$r['receipt_code'])
@section('panel')
@include('partials.flash')
@php
    $draft = $r['status'] === 'draft';
    $tone = ['draft' => 'average', 'approved' => 'high', 'cancelled' => 'info'];
    $when = fn ($t) => $t ? \Carbon\Carbon::parse($t)->setTimezone(config('app.timezone'))->format('M j, Y g:i A') : '—';
    $lines = old('lines', $r['lines']);
    $minExpiry = now('Asia/Manila')->addDay()->toDateString();
@endphp

<a class="btn-outline" style="padding:.3rem .9rem;width:fit-content" href="{{ route('receipts.index') }}">&larr; Receiving</a>

<section class="stat-row">
    <div class="stat"><span>Status</span><strong style="font-size:1.1rem"><span class="status {{ $tone[$r['status']] }}">{{ ucfirst($r['status']) }}</span></strong></div>
    <div class="stat"><span>Lines total</span><strong>{{ $peso($r['lines_total']) }}</strong></div>
    <div class="stat"><span>Invoice total (printed)</span><strong>{{ $peso($r['invoice_total']) }}</strong></div>
    <div class="stat"><span>{{ $r['source'] === 'ocr' ? 'OCR confidence' : 'Source' }}</span><strong>{{ $r['source'] === 'ocr' ? ($r['ocr_confidence'] !== null ? round($r['ocr_confidence']).'%' : '—') : 'Manual' }}</strong></div>
</section>
@if ($r['invoice_total'] !== null && abs((float) $r['lines_total'] - (float) $r['invoice_total']) > 1)
    <div class="card" style="max-width:none;border-color:#C98A1B;background:#fff8e8">The lines add up to {{ $peso($r['lines_total']) }} but the invoice says {{ $peso($r['invoice_total']) }}. A line may be missing or misread (VAT or discounts can also explain a difference).</div>
@endif
<p class="muted">Created by {{ $r['created_by'] }} · {{ $when($r['created_at']) }}
    @if ($r['approved_at']) · approved by {{ $r['approved_by'] }} · {{ $when($r['approved_at']) }} @endif
    @if ($r['cancelled_at']) · cancelled {{ $when($r['cancelled_at']) }}: {{ $r['cancel_reason'] }} @endif</p>

<div style="display:flex;flex-wrap:wrap;gap:1rem;align-items:flex-start">
@if ($r['document_path'] || $r['ocr_text'])
    <div class="card" style="flex:1 1 16rem;max-width:22rem;position:sticky;top:1rem">
        <strong>The paper invoice</strong>
        @if ($r['document_path'])
            <a href="{{ route('receipts.image', $r['id']) }}" target="_blank" rel="noopener"><img src="{{ route('receipts.image', $r['id']) }}" alt="Scanned invoice" style="width:100%;border:1px solid #e5dccf;border-radius:8px;margin-top:.5rem"></a>
        @endif
        @if ($r['ocr_text'])
            <details style="margin-top:.6rem"><summary>Text OCR read</summary>
                <pre style="white-space:pre-wrap;font-size:.8rem;max-height:420px;overflow:auto">{{ $r['ocr_text'] }}</pre></details>
        @endif
    </div>
@endif

<div style="flex:3 1 36rem;min-width:0">
@if ($draft)
<form data-hard method="POST" action="{{ route('receipts.update', $r['id']) }}" class="card" style="max-width:none" id="receipt-form">
    @csrf
    <input type="hidden" name="request_key" value="{{ $requestKey }}">
    <div style="display:flex;flex-wrap:wrap;gap:1rem">
        <div class="field" style="flex:1 1 12rem"><label>Branch</label>
            <select class="light-input" name="branch_id" required>@foreach ($branches as $b)<option value="{{ $b['id'] }}" @selected(old('branch_id', $r['branch_id']) === $b['id'])>{{ $b['name'] }}</option>@endforeach</select></div>
        <div class="field" style="flex:1 1 12rem"><label>Supplier</label>
            <select class="light-input" name="supplier_id"><option value="">— choose —</option>
                @foreach ($suppliers as $s)<option value="{{ $s['id'] }}" @selected(old('supplier_id', $r['supplier_id']) === $s['id'])>{{ $s['name'] }}{{ $s['is_active'] ? '' : ' (inactive)' }}</option>@endforeach</select>
            <a href="{{ route('suppliers.index') }}" class="muted" style="font-size:.8rem">Add a supplier</a></div>
        <div class="field" style="flex:1 1 9rem"><label>Invoice no.</label>
            <input class="light-input" name="supplier_invoice_no" maxlength="40" value="{{ old('supplier_invoice_no', $r['supplier_invoice_no']) }}"></div>
        <div class="field" style="flex:1 1 9rem"><label>Invoice date</label>
            <input class="light-input" type="date" name="invoice_date" value="{{ old('invoice_date', $r['invoice_date']) }}"></div>
        <div class="field" style="flex:1 1 9rem"><label>Printed total (₱)</label>
            <input class="light-input" type="number" step="0.01" min="0" name="invoice_total" value="{{ old('invoice_total', $r['invoice_total']) }}"></div>
    </div>

    <div style="overflow-x:auto">
    <table class="table" id="lines" data-no-paginate>
        <thead><tr><th>#</th><th style="min-width:12rem">Product (check!)</th><th>Qty</th><th>Unit cost · total</th><th>Expiry · batch</th><th></th></tr></thead>
        <tbody>
        @foreach ($lines as $i => $l)
            <tr class="line" @if (empty($l['variant_id'])) style="background:#fff8e8" @endif>
                <td class="n">{{ $i + 1 }}</td>
                <td>
                    @if (! empty($l['raw_text']))<div class="muted" style="font-size:.75rem;font-family:ui-monospace,monospace" title="What OCR read">{{ $l['raw_text'] }}</div>@endif
                    <input type="hidden" name="lines[{{ $i }}][raw_text]" value="{{ $l['raw_text'] ?? '' }}">
                    <input class="light-input" name="lines[{{ $i }}][description]" value="{{ $l['description'] ?? '' }}" maxlength="200" placeholder="Description" style="margin-bottom:.3rem">
                    <select class="light-input" name="lines[{{ $i }}][variant_id]">
                        <option value="">— match a product —</option>
                        @foreach ($variants as $v)<option value="{{ $v['id'] }}" @selected(($l['variant_id'] ?? null) === $v['id'])>{{ $v['label'] }}</option>@endforeach
                    </select>
                </td>
                <td><input class="light-input qty" type="number" min="1" max="100000" step="1" name="lines[{{ $i }}][quantity]" value="{{ $l['quantity'] ?? '' }}" style="width:4.8rem"></td>
                <td><input class="light-input cost" type="number" min="0" step="0.01" name="lines[{{ $i }}][unit_cost]" value="{{ $l['unit_cost'] ?? '' }}" style="width:6.5rem">
                    <div class="lt muted" style="font-size:.8rem;margin-top:.3rem">—</div></td>
                <td><input class="light-input" type="date" min="{{ $minExpiry }}" name="lines[{{ $i }}][expiration_date]" value="{{ $l['expiration_date'] ?? '' }}" style="width:9.5rem;margin-bottom:.3rem" aria-label="Expiry date">
                    <input class="light-input" name="lines[{{ $i }}][batch_code]" maxlength="40" value="{{ $l['batch_code'] ?? '' }}" placeholder="Batch (auto)" style="width:9.5rem" aria-label="Batch code"></td>
                <td><button type="button" class="btn-outline remove" style="padding:.2rem .6rem" title="Remove line">✕</button></td>
            </tr>
        @endforeach
        </tbody>
        <tfoot><tr><td colspan="3" style="text-align:right"><strong>Lines total</strong></td><td id="sum" colspan="3"><strong>—</strong></td></tr></tfoot>
    </table>
    </div>
    <button type="button" class="btn-outline" style="padding:.35rem .9rem" id="add-line">+ Add line</button>

    <div class="field" style="margin-top:1rem"><label>Notes</label>
        <input class="light-input" name="notes" maxlength="500" value="{{ old('notes', $r['notes']) }}"></div>

    <p class="muted">Highlighted lines have no product yet. Every line needs a product, quantity, unit cost and an expiry date before approval. A blank batch code becomes {{ $r['receipt_code'] }}-&lt;line&gt;.</p>
    <div style="display:flex;gap:.6rem;flex-wrap:wrap">
        <button class="btn-outline" style="padding:.5rem 1.2rem" type="submit" name="action" value="save">Save draft</button>
        <button class="btn-solid" style="padding:.5rem 1.2rem" type="submit" name="action" value="approve"
                data-confirm="Add these items to stock at the selected branch? This cannot be undone (use an inventory adjustment to correct mistakes)." data-confirm-title="Approve and receive stock?" data-confirm-label="Approve &amp; receive" data-confirm-safe>Approve &amp; receive stock</button>
    </div>
</form>

<template id="line-template">
    <tr class="line" style="background:#fff8e8">
        <td class="n"></td>
        <td><input type="hidden" data-name="raw_text" value="">
            <input class="light-input" data-name="description" maxlength="200" placeholder="Description" style="margin-bottom:.3rem">
            <select class="light-input" data-name="variant_id"><option value="">— match a product —</option>
                @foreach ($variants as $v)<option value="{{ $v['id'] }}">{{ $v['label'] }}</option>@endforeach</select></td>
        <td><input class="light-input qty" type="number" min="1" max="100000" step="1" data-name="quantity" style="width:4.8rem"></td>
        <td><input class="light-input cost" type="number" min="0" step="0.01" data-name="unit_cost" style="width:6.5rem">
            <div class="lt muted" style="font-size:.8rem;margin-top:.3rem">—</div></td>
        <td><input class="light-input" type="date" min="{{ $minExpiry }}" data-name="expiration_date" style="width:9.5rem;margin-bottom:.3rem" aria-label="Expiry date">
            <input class="light-input" data-name="batch_code" maxlength="40" placeholder="Batch (auto)" style="width:9.5rem" aria-label="Batch code"></td>
        <td><button type="button" class="btn-outline remove" style="padding:.2rem .6rem" title="Remove line">✕</button></td>
    </tr>
</template>

<form data-hard method="POST" action="{{ route('receipts.cancel', $r['id']) }}" class="card" style="max-width:none;display:flex;gap:.6rem;flex-wrap:wrap;align-items:center" data-confirm="Cancel this draft receipt? Nothing is added to stock." data-confirm-title="Cancel this draft?" data-confirm-label="Cancel draft">
    @csrf
    <span class="muted">Wrong scan or duplicate?</span>
    <input class="light-input" name="reason" required minlength="3" maxlength="200" placeholder="Reason" style="max-width:18rem">
    <button class="btn-outline" style="padding:.35rem .9rem" type="submit">Cancel draft</button>
</form>

<script>
(function () {
    var body = document.querySelector('#lines tbody'), tpl = document.getElementById('line-template');
    var peso = function (n) { return '₱' + n.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); };
    function renumber() {
        Array.prototype.forEach.call(body.querySelectorAll('tr.line'), function (tr, i) {
            tr.querySelector('.n').textContent = i + 1;
            tr.querySelectorAll('[name], [data-name]').forEach(function (el) {
                var key = el.dataset.name || el.name.replace(/^lines\[\d+\]\[(\w+)\]$/, '$1');
                el.dataset.name = key; el.name = 'lines[' + i + '][' + key + ']';
            });
        });
        recalc();
    }
    function recalc() {
        var sum = 0;
        body.querySelectorAll('tr.line').forEach(function (tr) {
            var q = parseFloat(tr.querySelector('.qty').value), c = parseFloat(tr.querySelector('.cost').value);
            var ok = !isNaN(q) && !isNaN(c);
            tr.querySelector('.lt').textContent = ok ? peso(q * c) : '—';
            if (ok) sum += q * c;
            var sel = tr.querySelector('select');
            tr.style.background = sel && sel.value ? '' : '#fff8e8';
        });
        document.getElementById('sum').innerHTML = '<strong>' + peso(sum) + '</strong>';
    }
    body.addEventListener('input', recalc);
    body.addEventListener('change', recalc);
    body.addEventListener('click', function (e) {
        if (e.target.classList.contains('remove')) { e.target.closest('tr').remove(); renumber(); }
    });
    document.getElementById('add-line').addEventListener('click', function () {
        body.appendChild(tpl.content.firstElementChild.cloneNode(true)); renumber();
    });
    renumber();
})();
</script>
@else
<div class="card" style="max-width:none;overflow-x:auto">
    <p style="margin-top:0"><strong>{{ $r['supplier_name'] ?? '—' }}</strong> · invoice {{ $r['supplier_invoice_no'] ?? '—' }} · {{ $r['invoice_date'] ?? '—' }} · {{ $r['branch_name'] }}</p>
    <table class="table">
        <thead><tr><th>#</th><th>Product</th><th>Qty</th><th>Unit cost</th><th>Line total</th><th>Batch</th><th>Expiry</th></tr></thead>
        <tbody>
        @foreach ($r['lines'] as $l)
            <tr><td>{{ $l['line_no'] }}</td><td>{{ $l['variant_name'] ?? $l['description'] }}@if ($l['raw_text'])<div class="muted" style="font-size:.75rem">{{ $l['raw_text'] }}</div>@endif</td>
                <td>{{ $l['quantity'] ?? '—' }}</td><td>{{ $peso($l['unit_cost']) }}</td><td>{{ $peso($l['line_total']) }}</td>
                <td>{{ $l['batch_code'] ?? '—' }}</td><td>{{ $l['expiration_date'] ?? '—' }}</td></tr>
        @endforeach
        </tbody>
    </table>
    @if ($r['notes'])<p class="muted">Notes: {{ $r['notes'] }}</p>@endif
</div>
@endif
</div>
</div>
@endsection
