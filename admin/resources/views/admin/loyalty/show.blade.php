@extends('layouts.panel')
@section('title', $member['name'].' · Loyalty · Melai Nuts Admin')
@section('page-title', 'Loyalty — '.$member['name'])
@section('panel')
@php
    $labels = ['earned' => 'Earned', 'redeemed' => 'Redeemed', 'refunded' => 'Reversed (order refunded)', 'adjusted' => 'Manual adjustment', 'returned' => 'Returned (cancelled order)'];
    $tone = ['earned' => 'high', 'redeemed' => 'info', 'refunded' => 'low', 'adjusted' => 'average', 'returned' => 'info'];
@endphp

@if (session('status')) <div class="card" style="border-color:#2E7D4F;background:#f1f8f2">{{ session('status') }}</div> @endif
@if (session('error')) <div class="card" style="border-color:#C0392B;background:#fdecea">{{ session('error') }}</div> @endif
@if ($errors->any())
    <div class="card" style="border-color:#C0392B;background:#fdecea">
        <ul style="margin:0;padding-left:1.1rem">@foreach ($errors->all() as $e) <li>{{ $e }}</li> @endforeach</ul>
    </div>
@endif

<a class="btn-outline" style="padding:.3rem .9rem;width:fit-content" href="{{ route('loyalty.index') }}">&larr; Back to members</a>

<div class="stat-row">
    <div class="stat"><span>Current balance</span><strong>{{ $member['balance'] }}</strong></div>
    <div class="stat"><span>Total earned</span><strong>{{ $member['earned'] }}</strong></div>
    <div class="stat"><span>Total redeemed</span><strong>{{ $member['redeemed'] }}</strong></div>
    <div class="stat"><span>Reversed by refunds</span><strong>{{ $member['refunded'] }}</strong></div>
</div>

<div class="card" style="max-width:28rem">
    <p class="muted" style="margin:0">{{ $member['email'] }} · Card {{ $member['cardNumber'] }}@if ($member['tier']) · {{ $member['tier'] }} tier @endif</p>
</div>

@if (auth()->user()->isAdmin())
<div class="block-head"><h2>Manual adjustment</h2></div>
<div class="card" style="max-width:28rem">
    <form method="POST" action="{{ route('admin.loyalty.adjust', $member['id']) }}" onsubmit="this.querySelector('button[type=submit]').disabled = true">
        @csrf
        <input type="hidden" name="request_key" value="{{ $requestKey }}">
        <p class="muted" style="margin-top:0">The customer is notified in the app, and the change is added to their points history.</p>
        <div class="field">
            <label>Points (positive to add, negative to deduct)</label>
            <input class="light-input" type="number" name="points" value="{{ old('points') }}" placeholder="e.g. 50 or -50">
        </div>
        <div class="field">
            <label>Reason</label>
            <input class="light-input" name="reason" value="{{ old('reason') }}" placeholder="Required">
        </div>
        <x-password-confirm />
        <button class="btn-solid" type="submit">Save adjustment</button>
    </form>
</div>
@endif

<div class="block-head"><h2>Points history</h2></div>
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Date</th><th>Type</th><th>Order</th><th>Points</th><th>Reason</th></tr></thead>
        <tbody>
        @forelse (array_reverse($member['pointsHistory']) as $h)
            <tr>
                <td>{{ $h['at']->format('M j, Y g:i A') }}</td>
                <td><span class="status {{ $tone[$h['type']] ?? 'info' }}">{{ $labels[$h['type']] ?? ucfirst($h['type']) }}</span>
                </td>
                <td>{{ $h['order_id'] ?? '—' }}</td>
                <td>{{ $h['points'] > 0 ? '+' : '' }}{{ $h['points'] }}</td>
                <td class="muted">{{ $h['reason'] ?? '—' }}</td>
            </tr>
        @empty
            <tr><td colspan="5">No points activity yet.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
@endsection
