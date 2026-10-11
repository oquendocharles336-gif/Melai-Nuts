@extends('layouts.panel')
@section('title', $member['name'].' · Loyalty Cards · Melai Nuts Admin')
@section('page-title', 'Loyalty Cards — '.$member['name'])
@section('panel')
@include('partials.flash')
@php
    $active = collect($cards)->firstWhere('status', 'active');
    $blocked = collect($cards)->firstWhere('status', 'blocked');
    $tone = ['active' => 'high', 'blocked' => 'low', 'replaced' => 'info'];
    $when = fn ($t) => $t ? \Carbon\Carbon::parse($t)->setTimezone(config('app.timezone'))->format('M j, Y g:i A') : '—';
@endphp

<a class="btn-outline" style="padding:.3rem .9rem;width:fit-content" href="{{ route('cards.index') }}">&larr; Loyalty cards</a>

<section class="stat-row">
    <div class="stat"><span>Customer</span><strong style="font-size:1.1rem">{{ $member['name'] }}</strong></div>
    <div class="stat"><span>Points balance</span><strong>{{ $member['balance'] }}</strong></div>
    <div class="stat"><span>Active card</span><strong style="font-size:1.1rem">{{ $active['label'] ?? 'None' }}</strong></div>
</section>
<p class="muted">{{ $member['email'] }} · <a href="{{ route('loyalty.show', $member['id']) }}">Points history</a></p>

@include('cards._reader', ['readerTitle' => $active || $blocked ? 'Tap the NEW card' : 'Tap the card to link'])

@if (! $active && ! $blocked)
    <div class="block-head"><h2>Link a card</h2></div>
    <form method="POST" action="{{ route('cards.register', $member['id']) }}" class="card" style="max-width:32rem" onsubmit="this.querySelector('button[type=submit]').disabled = true">
        @csrf
        <input type="hidden" name="request_key" value="{{ $requestKey }}">
        <div class="field"><label>Card number (filled in by the reader)</label>
            <input class="light-input" name="card_uid" data-card-target value="{{ old('card_uid') }}" required maxlength="64" autocomplete="off" placeholder="Tap the card"></div>
        <button class="btn-solid" type="submit">Link card to {{ $member['name'] }}</button>
    </form>
@else
    <div class="block-head"><h2>Replace card (lost or damaged)</h2></div>
    <form method="POST" action="{{ route('cards.replace', $member['id']) }}" class="card" style="max-width:32rem" onsubmit="this.querySelector('button[type=submit]').disabled = true">
        @csrf
        <input type="hidden" name="request_key" value="{{ $requestKey }}">
        <div class="field"><label>New card number (filled in by the reader)</label>
            <input class="light-input" name="card_uid" data-card-target value="{{ old('card_uid') }}" required maxlength="64" autocomplete="off" placeholder="Tap the new card"></div>
        <div class="field"><label>Reason</label>
            <input class="light-input" name="reason" value="{{ old('reason') }}" required minlength="3" maxlength="200" placeholder="e.g. lost, damaged"></div>
        <p class="muted" style="margin-top:0">The old card ({{ ($active ?? $blocked)['label'] }}) stops working at once. Points stay with the customer.</p>
        <button class="btn-solid" type="submit">Replace card</button>
    </form>
@endif

<div class="block-head"><h2>Cards and history</h2></div>
@forelse ($cards as $card)
    <div class="card" style="max-width:none">
        <div style="display:flex;flex-wrap:wrap;gap:1rem;align-items:center;justify-content:space-between">
            <div><strong style="font-size:1.1rem">{{ $card['label'] }}</strong>
                <span class="status {{ $tone[$card['status']] ?? 'info' }}">{{ ucfirst($card['status']) }}</span>
                <span class="muted">· issued {{ $when($card['issued_at']) }} @if ($card['issued_branch']) at {{ $card['issued_branch'] }} @endif</span>
                @if ($card['block_reason']) <br><span class="muted">Reason: {{ $card['block_reason'] }}</span> @endif
            </div>
            <div style="display:flex;gap:.5rem;flex-wrap:wrap">
                @if ($card['status'] === 'active')
                    <form method="POST" action="{{ route('cards.block', $card['id']) }}" style="display:flex;gap:.4rem" onsubmit="return confirm('Block card {{ $card['label'] }}? It will stop working at every branch.')">
                        @csrf
                        <input class="light-input" name="reason" required minlength="3" maxlength="200" placeholder="Reason (e.g. reported lost)" style="max-width:14rem">
                        <button class="btn-outline" style="padding:.3rem .9rem;border-color:#C0392B;color:#C0392B" type="submit">Block</button>
                    </form>
                @elseif ($card['status'] === 'blocked' && $isOwner)
                    <form method="POST" action="{{ route('cards.unblock', $card['id']) }}">@csrf
                        <button class="btn-outline" style="padding:.3rem .9rem" type="submit">Unblock (card found)</button></form>
                @endif
            </div>
        </div>
        <table class="table" style="margin-top:.6rem">
            <thead><tr><th>When</th><th>Event</th><th>By</th><th>Branch</th><th>Note</th></tr></thead>
            <tbody>
            @foreach ($card['events'] ?? [] as $e)
                <tr><td>{{ $when($e['at']) }}</td><td>{{ ucfirst($e['event']) }}</td><td>{{ $e['by'] ?? 'System' }}</td><td>{{ $e['branch'] ?? '—' }}</td><td class="muted">{{ $e['note'] }}</td></tr>
            @endforeach
            </tbody>
        </table>
    </div>
@empty
    <div class="card" style="max-width:none">No card linked yet.</div>
@endforelse

<script>
    // A tap fills the card field and puts focus on the next step.
    window.onCardTap = function (uid) {
        var f = document.querySelector('[data-card-target]');
        if (!f) return;
        f.value = uid;
        var next = f.form.querySelector('input[name=reason]');
        (next && !next.value ? next : f.form.querySelector('button[type=submit]')).focus();
    };
</script>
@endsection
