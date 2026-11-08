@extends('layouts.shop')

@section('title', 'Golden Kernel points')

@section('content')
    <h1 class="s-title">Golden Kernel points</h1>

    @if ($error)
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="alert" :size="28" /></span>
            <h3>We couldn't load your points</h3>
            <p>{{ $error }}</p>
            <a href="{{ route('shop.points') }}" class="s-btn primary">Try again</a>
        </div>
    @else
        <div class="s-points-hero">
            <span>Available points</span>
            <b>{{ number_format($points['balance']) }}</b>
            <span>Use them at checkout on the website or in the app. Same balance everywhere.</span>
        </div>

        <section class="s-panel" aria-labelledby="hist-title">
            <h2 id="hist-title">History</h2>
            @if ($points['history'] === [])
                <p class="s-sub">No points yet. You earn points when a pickup order is completed.</p>
            @else
                <div class="s-lines">
                    @foreach ($points['history'] as $t)
                        @php($earn = $t['points'] >= 0 && $t['type'] !== 'redeem')
                        <div class="s-line" style="grid-template-columns:minmax(0,1fr) auto">
                            <div><b>{{ $t['note'] !== '' ? $t['note'] : ucfirst($t['type']) }}</b>
                                <small>{{ $t['created_at'] ? \Illuminate\Support\Carbon::parse($t['created_at'])->timezone('Asia/Manila')->format('M j, Y') : '' }}</small></div>
                            <b class="tabular" style="color:{{ $earn ? 'var(--ok)' : 'var(--bad)' }}">{{ $earn ? '+' : '−' }}{{ number_format(abs($t['points'])) }}</b>
                        </div>
                    @endforeach
                </div>
            @endif
        </section>
    @endif
@endsection
