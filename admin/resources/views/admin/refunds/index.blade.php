@extends('layouts.panel')
@section('title', 'Refunds · Melai Nuts Admin')
@section('page-title', 'Refunds')
@section('panel')
@php $peso = fn ($n) => '₱'.number_format($n, 2);
$methodLabel = fn ($m) => ['cod' => 'COD', 'cash' => 'Cash', 'gcash' => 'GCash', 'maya' => 'Maya', 'card' => 'Card'][$m] ?? strtoupper($m);
$labels = ['requested' => 'Requested', 'approved_processing' => 'Approved · send money back', 'rejected' => 'Rejected', 'refunded' => 'Refunded', 'failed' => 'Failed'];
$tone = ['requested' => 'average', 'approved_processing' => 'info', 'rejected' => 'low', 'refunded' => 'high', 'failed' => 'low'];
@endphp

@if (session('status')) <div class="card" style="border-color:#2E7D4F;background:#f1f8f2">{{ session('status') }}</div> @endif
@if (session('error')) <div class="card" style="border-color:#C0392B;background:#fdecea">{{ session('error') }}</div> @endif
@if ($errors->any())
    <div class="card" style="border-color:#C0392B;background:#fdecea">
        <ul style="margin:0;padding-left:1.1rem">@foreach ($errors->all() as $e) <li>{{ $e }}</li> @endforeach</ul>
    </div>
@endif

<p class="muted">Refund requests made in the Melai Nuts app. The amount is fixed by the request (partial refunds cover only the returned items) and can never be more than what was paid minus refunds already completed on the order. Once completed it is deducted from net sales on the day it completed, everywhere (dashboard, reports, the app). Cash refunds are completed in one step. Online (GCash / Maya / card) refunds are approved here, then sent back with "Send via HitPay" (needs HITPAY_API_KEY), or refunded from the HitPay dashboard and marked refunded with the reference.</p>

<form method="GET" class="card filter-row">
    <select class="light-input" name="status" onchange="this.form.submit()">
        <option value="">All statuses</option>
        @foreach ($labels as $k => $label) <option value="{{ $k }}" @selected(($filters['status'] ?? '') === $k)>{{ $label }}</option> @endforeach
    </select>
    <select class="light-input" name="branch" onchange="this.form.submit()">
        <option value="">All branches</option>
        @foreach ($branches as $b) <option value="{{ $b['id'] }}" @selected(($filters['branch'] ?? '') === $b['id'])>{{ $b['name'] }}</option> @endforeach
    </select>
    <input class="light-input" type="search" name="q" value="{{ $q }}" placeholder="Order, request, customer, reason" aria-label="Search refunds" maxlength="100">
    <button class="btn-outline" type="submit" style="padding:.5rem 1rem">Search</button>
    @if (array_filter($filters) || $q !== '') <a href="{{ route('admin.refunds.index') }}" class="btn-outline" style="padding:.5rem 1rem">Clear</a> @endif
    <a class="btn-outline" style="padding:.5rem 1rem" href="{{ route('admin.refunds.export', request()->only(['status', 'method', 'branch', 'q'])) }}">Download CSV</a>
</form>

<div class="grid-4" style="grid-template-columns:repeat(auto-fit,minmax(20rem,1fr))">
@forelse ($refunds as $r)
    <div class="card-b" style="text-align:left">
        <div class="card-top">
            <strong>{{ $r['id'] }}</strong>
            <span class="status {{ $tone[$r['effectiveRefundStatus']] ?? 'info' }}">{{ $labels[$r['effectiveRefundStatus']] ?? $r['effectiveRefundStatus'] }}</span>
        </div>
        @php $refundAmount = $r['refundAmount']; @endphp
        <p class="muted" style="margin:.25rem 0">{{ $r['branchName'] ?? (collect($branches)->firstWhere('id', $r['branch'])['name'] ?? '—') }} · {{ $methodLabel($r['paymentMethod']) }} · {{ $r['createdAt']->format('M j, g:i A') }}</p>
        <p style="margin:.4rem 0"><strong>{{ $r['customer'] }}</strong> — {{ $peso($refundAmount) }}@if ($refundAmount != $r['total']) <span class="muted">of {{ $peso($r['total']) }} (partial)</span>@endif</p>
        @if (($r['refundedAmount'] ?? null) !== null && $r['refundedAmount'] > 0)
            <p class="muted" style="margin:0">Already refunded on this order: {{ $peso($r['refundedAmount']) }}@if (($r['pointsReversed'] ?? 0) > 0) · {{ $r['pointsReversed'] }} points reversed @endif</p>
        @endif
        @if (in_array($r['effectiveRefundStatus'], ['requested', 'approved_processing'], true) && ($r['refundableAmount'] ?? null) !== null)
            <p class="muted" style="margin:0">Left to refund on this order: {{ $peso($r['refundableAmount']) }}@if ($refundAmount > $r['refundableAmount'] + 0.004) — <strong style="color:var(--bad)">more than what was paid; the database will refuse it</strong>@endif</p>
        @endif
        @if (! empty($r['refundId'])) <p class="muted" style="margin:0">Request {{ $r['refundId'] }}</p> @endif
        <p class="muted" style="margin:.2rem 0 .6rem">"{{ $r['refundReason'] }}"</p>

        @if ($r['effectiveRefundStatus'] === 'requested')
            <div class="refund-actions">
                <form method="POST" action="{{ route('admin.refunds.approve', $r['id']) }}" onsubmit="return confirm('Approve this refund of {{ $peso($refundAmount) }}?')">
                    @csrf
                    @if ($r['paymentMethod'] === $cashMethod)
                        <input type="hidden" name="note" value="Refunded in cash on delivery return.">
                    @endif
                    <x-password-confirm />
                    <button class="btn-solid" type="submit" style="padding:.45rem 1rem">Approve</button>
                </form>
                <button class="btn-outline" type="button" style="padding:.45rem 1rem" onclick="document.getElementById('reject-{{ $r['id'] }}').showModal()">Reject</button>
            </div>
            <dialog id="reject-{{ $r['id'] }}" class="reject-dialog">
                <form method="POST" action="{{ route('admin.refunds.reject', $r['id']) }}">
                    @csrf
                    <p><strong>Reject refund for {{ $r['id'] }}</strong></p>
                    <textarea class="light-input" name="reason" rows="3" placeholder="Reason (required)" required></textarea>
                    <div class="btn-row" style="justify-content:flex-start;margin-top:.75rem">
                        <button class="btn-solid" type="submit" style="padding:.45rem 1rem">Confirm reject</button>
                        <button class="btn-outline" type="button" style="padding:.45rem 1rem" onclick="this.closest('dialog').close()">Cancel</button>
                    </div>
                </form>
            </dialog>
        @elseif ($r['effectiveRefundStatus'] === 'approved_processing')
            @php $att = $attempts[$r['refundId']] ?? null; @endphp
            @if ($att)
                <p class="muted" style="margin:.3rem 0">HitPay: <span class="status {{ ['sending' => 'average', 'pending' => 'info', 'failed' => 'low', 'succeeded' => 'high'][$att['status']] ?? 'info' }}">{{ ucfirst($att['status']) }}</span>
                    @if ($att['gateway_refund_id']) · refund {{ $att['gateway_refund_id'] }} @endif
                    @if ($att['error']) · {{ $att['error'] }} @endif</p>
            @endif
            @if ($hitpayReady && $r['paymentMethod'] !== 'cash')
                @if ($att && $att['status'] === 'pending')
                    <form method="POST" action="{{ route('admin.refunds.hitpay.check', $r['id']) }}" style="margin-bottom:.5rem">@csrf
                        <input type="hidden" name="attempt_id" value="{{ $att['attempt_id'] }}">
                        <button class="btn-outline" type="submit" style="padding:.4rem .9rem">Check HitPay</button></form>
                @elseif ($att && $att['status'] === 'sending')
                    <form method="POST" action="{{ route('admin.refunds.hitpay.abandon', $r['id']) }}" class="refund-actions" style="flex-wrap:wrap;margin-bottom:.5rem">@csrf
                        <input type="hidden" name="attempt_id" value="{{ $att['attempt_id'] }}">
                        <input class="light-input" name="note" required minlength="5" maxlength="200" placeholder="HitPay never answered: what does the dashboard show?" style="flex:1;min-width:12rem">
                        <button class="btn-outline" type="submit" style="padding:.4rem .9rem">Close attempt</button></form>
                @else
                    <form method="POST" action="{{ route('admin.refunds.hitpay', $r['id']) }}" style="margin-bottom:.5rem"
                          onsubmit="this.querySelector('button').disabled = true; return confirm('Send {{ $peso($r['refundAmount']) }} back to the customer through HitPay now?')">@csrf
                        <x-password-confirm />
                        <button class="btn-solid" type="submit" style="padding:.45rem 1rem">Send {{ $peso($r['refundAmount']) }} via HitPay</button></form>
                @endif
                <p class="muted" style="margin:.2rem 0">Or, if you refunded from the HitPay dashboard:</p>
            @endif
            <form method="POST" action="{{ route('admin.refunds.complete', $r['id']) }}" class="refund-actions" style="flex-wrap:wrap">
                @csrf
                <input class="light-input" name="reference" placeholder="HitPay refund reference" required minlength="4" maxlength="120" style="flex:1;min-width:10rem">
                <x-password-confirm />
                <button class="btn-solid" type="submit" style="padding:.45rem 1rem">Mark refunded</button>
            </form>
            <button class="btn-outline" type="button" style="padding:.4rem .9rem;margin-top:.5rem" onclick="document.getElementById('reject-{{ $r['id'] }}').showModal()">Reject</button>
            <dialog id="reject-{{ $r['id'] }}" class="reject-dialog">
                <form method="POST" action="{{ route('admin.refunds.reject', $r['id']) }}">
                    @csrf
                    <p><strong>Reject refund for {{ $r['id'] }}</strong></p>
                    <textarea class="light-input" name="reason" rows="3" placeholder="Reason (required, sent to the customer)" required></textarea>
                    <div class="btn-row" style="justify-content:flex-start;margin-top:.75rem">
                        <button class="btn-solid" type="submit" style="padding:.45rem 1rem">Confirm reject</button>
                        <button class="btn-outline" type="button" style="padding:.45rem 1rem" onclick="this.closest('dialog').close()">Cancel</button>
                    </div>
                </form>
            </dialog>
        @endif
    </div>
@empty
    <div class="card">No refund requests match these filters.</div>
@endforelse
</div>
@if ($refunds->hasPages())<div style="margin-top:12px">{{ $refunds->links() }}</div>@endif
@endsection
