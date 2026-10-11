@extends('layouts.panel')
@section('title', 'Loyalty Cards · Melai Nuts Admin')
@section('page-title', 'Loyalty Cards (RFID)')
@section('panel')
@include('partials.flash')

@include('cards._reader', ['readerTitle' => 'Tap a card to see whose it is'])
<div id="tap-result" class="card" style="max-width:none;display:none"></div>

<div class="block-head"><h2>Find a customer</h2></div>
<form method="POST" action="{{ route('cards.find') }}" class="card" style="max-width:none;display:flex;flex-wrap:wrap;gap:.8rem;align-items:end">
    @csrf
    <div style="flex:1 1 18rem"><label for="query"><strong>Exact phone, e-mail or printed card label (GK-…)</strong></label><br>
        <input class="light-input" id="query" name="query" value="{{ old('query') }}" required minlength="4" maxlength="120" placeholder="09171234567 or juan@email.com"></div>
    <button class="btn-solid" style="padding:.5rem 1.2rem" type="submit">Open customer</button>
</form>
<p class="muted">To give a customer a card: find them, then tap the new card on their page. Points belong to the customer, not the card, so a lost card can be blocked and replaced without losing points.</p>

@if ($isOwner && $list)
    @php $c = $list['counts'] ?? []; @endphp
    <section class="stat-row">
        <div class="stat"><span>Active cards</span><strong>{{ $c['active'] ?? 0 }}</strong></div>
        <div class="stat"><span>Blocked</span><strong>{{ $c['blocked'] ?? 0 }}</strong></div>
        <div class="stat"><span>Replaced</span><strong>{{ $c['replaced'] ?? 0 }}</strong></div>
    </section>

    <div class="block-head"><h2>All cards</h2></div>
    <form method="GET" class="card" style="max-width:none;display:flex;flex-wrap:wrap;gap:.8rem;align-items:end">
        <div><label for="q"><strong>Search</strong></label><br><input class="light-input" id="q" name="q" value="{{ $q }}" placeholder="Name, e-mail, phone or GK-…"></div>
        <div><label for="status"><strong>Status</strong></label><br>
            <select class="light-input" id="status" name="status">
                <option value="">All</option>
                @foreach (['active' => 'Active', 'blocked' => 'Blocked', 'replaced' => 'Replaced'] as $k => $v)<option value="{{ $k }}" @selected($status === $k)>{{ $v }}</option>@endforeach
            </select></div>
        <button class="btn-solid" style="padding:.5rem 1.2rem" type="submit">Filter</button>
    </form>
    <div class="card" style="max-width:none;overflow-x:auto">
        <table class="table">
            <thead><tr><th>Card</th><th>Status</th><th>Customer</th><th>Points</th><th>Issued</th><th>Branch</th><th></th></tr></thead>
            <tbody>
            @forelse ($list['cards'] ?? [] as $card)
                <tr>
                    <td><strong>{{ $card['label'] }}</strong></td>
                    <td><span class="status {{ ['active' => 'high', 'blocked' => 'low', 'replaced' => 'info'][$card['status']] ?? 'info' }}">{{ ucfirst($card['status']) }}</span></td>
                    <td>{{ $card['customer_name'] }}<br><span class="muted">{{ $card['email'] }}</span></td>
                    <td>{{ $card['points_balance'] }}</td>
                    <td>{{ \Carbon\Carbon::parse($card['issued_at'])->setTimezone(config('app.timezone'))->format('M j, Y') }}</td>
                    <td>{{ $card['issued_branch'] ?? '—' }}</td>
                    <td><a class="btn-outline" style="padding:.25rem .8rem" href="{{ route('cards.customer', $card['firebase_uid']) }}">Open</a></td>
                </tr>
            @empty
                <tr><td colspan="7">No cards yet.</td></tr>
            @endforelse
            </tbody>
        </table>
    </div>
@endif

<script>
    window.onCardTap = async function (uid) {
        var box = document.getElementById('tap-result');
        box.style.display = 'block';
        box.textContent = 'Checking card…';
        try {
            var res = await fetch(@json(route('cards.tap')), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Accept': 'application/json',
                           'X-CSRF-TOKEN': document.querySelector('meta[name=csrf-token]').content },
                body: JSON.stringify({ card_uid: uid })
            });
            var data = await res.json();
            box.innerHTML = '';
            var p = document.createElement('p'); p.style.margin = '0';
            if (!res.ok) { p.textContent = data.message || 'The card could not be checked.'; }
            else if (data.status === 'active') {
                p.innerHTML = '<span class="status high">Active</span> ';
                var b = document.createElement('strong'); b.textContent = data.card.label + ' — ' + data.customer.full_name + ' · ' + data.customer.points_balance + ' pts ';
                var a = document.createElement('a'); a.href = data.url; a.className = 'btn-outline'; a.style.padding = '.25rem .8rem'; a.textContent = 'Open customer';
                p.appendChild(b); p.appendChild(a);
            } else if (data.status === 'unregistered') {
                p.innerHTML = '<span class="status average">New card</span> This card is not linked to anyone. Find the customer below, then tap it again on their page.';
            } else {
                p.innerHTML = '<span class="status low">' + (data.status === 'blocked' ? 'Blocked' : 'Replaced') + '</span> ';
                p.appendChild(document.createTextNode('Card ' + data.card.label + ' cannot be used. Ask the customer for their phone or e-mail.'));
            }
            box.appendChild(p);
        } catch (e) { box.textContent = 'The card could not be checked. Check the connection and try again.'; }
    };
</script>
@endsection
