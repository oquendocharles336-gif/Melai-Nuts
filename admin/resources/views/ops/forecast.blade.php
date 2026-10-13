@extends('layouts.panel')
@section('title', 'Sales Forecast · Melai Nuts Admin')
@section('page-title', 'Sales Forecast')
@section('panel')
@php
    $fmt = fn ($n) => $n === null ? '—' : ($metric === 'revenue' ? \App\Support\Format::peso($n) : number_format((float) $n, 1));
    $ok = ($result['status'] ?? null) === 'ok';
@endphp
@include('partials.flash')

<form method="GET" class="card" style="max-width:none;display:flex;flex-wrap:wrap;gap:1rem;align-items:end">
    <input type="hidden" name="run" value="1">
    <div><label for="branch"><strong>Branch</strong></label><br>
        <select class="light-input" id="branch" name="branch">@foreach ($branches as $b)<option value="{{ $b['id'] }}" @selected($branchId === $b['id'])>{{ $b['name'] }}</option>@endforeach</select></div>
    <div><label for="variant"><strong>Product</strong></label><br>
        <select class="light-input" id="variant" name="variant"><option value="">All products</option>
            @foreach ($variants as $v)<option value="{{ $v['id'] }}" @selected($variantId === $v['id'])>{{ $v['label'] }}</option>@endforeach</select></div>
    <div><label for="metric"><strong>Measure</strong></label><br>
        <select class="light-input" id="metric" name="metric"><option value="units" @selected($metric === 'units')>Units sold</option><option value="revenue" @selected($metric === 'revenue')>Sales (₱)</option></select></div>
    <div><label for="granularity"><strong>By</strong></label><br>
        <select class="light-input" id="granularity" name="granularity"><option value="day" @selected($granularity === 'day')>Day</option><option value="week" @selected($granularity === 'week')>Week</option></select></div>
    <div><label for="horizon"><strong>Forecast ahead</strong></label><br><input class="light-input" type="number" id="horizon" name="horizon" min="1" max="{{ $granularity === 'day' ? 90 : 26 }}" value="{{ $horizon }}" style="width:5rem"></div>
    <div><label for="train_from"><strong>Learn from</strong></label><br><input class="light-input" type="date" id="train_from" name="train_from" value="{{ $trainFrom }}"></div>
    <div><label for="train_to"><strong>Learn until</strong></label><br><input class="light-input" type="date" id="train_to" name="train_to" value="{{ $trainTo }}"></div>
    <div><button class="btn-solid" style="padding:.5rem 1.2rem" type="submit">Run forecast</button></div>
</form>
<p class="muted">A linear regression on past verified sales (refunds taken out). Days the branch had no sales are treated as closed.
    Leave the dates empty to learn from the last 90 days (or 26 weeks) up to yesterday. <strong>Forecasts are estimates, not guaranteed sales.</strong></p>

@if ($result === null)
    <div class="card" style="max-width:none">Choose the options above and press <strong>Run forecast</strong>.</div>
@elseif (! $ok)
    <div class="card" style="max-width:none"><h2>Not enough history yet</h2><p>{{ $result['message'] ?? 'Not enough sales history.' }}</p></div>
@else
    @php
        $ev = $result['evaluation']; $m = $result['model'];
        $series = collect($result['history'])->map(fn ($h) => ['period' => $h['period'], 'actual' => $h['actual'], 'predicted' => null, 'lower' => null, 'upper' => null])
            ->concat(collect($result['forecast'])->map(fn ($f) => ['period' => $f['period'], 'actual' => null, 'predicted' => $f['predicted'], 'lower' => $f['lower'], 'upper' => $f['upper']]));
        $max = max(1, $series->max(fn ($p) => max($p['actual'] ?? 0, $p['upper'] ?? 0)));
        $w = 760; $h = 220; $n = max(1, $series->count() - 1);
        $x = fn ($i) => round($i / $n * $w, 1); $y = fn ($v) => round($h - $v / $max * $h, 1);
        $actualPts = $series->values()->map(fn ($p, $i) => $p['actual'] !== null ? $x($i).','.$y($p['actual']) : null)->filter()->implode(' ');
        $fcPts = $series->values()->map(fn ($p, $i) => $p['predicted'] !== null ? $x($i).','.$y($p['predicted']) : null)->filter()->implode(' ');
        $band = $series->values()->map(fn ($p, $i) => $p['upper'] !== null ? $x($i).','.$y($p['upper']) : null)->filter()
            ->concat($series->values()->map(fn ($p, $i) => $p['lower'] !== null ? $x($i).','.$y($p['lower']) : null)->filter()->reverse())->implode(' ');
    @endphp
    <section class="stat-row">
        <div class="stat"><span>Hold-out error (MAE)</span><strong>{{ $fmt($ev['mae']) }}</strong><span>average miss per {{ $granularity }} on the last {{ $ev['holdout_periods'] }} {{ $granularity }}s</span></div>
        <div class="stat"><span>Hold-out RMSE</span><strong>{{ $fmt($ev['rmse']) }}</strong><span>penalises big misses</span></div>
        <div class="stat"><span>Simple average would miss by</span><strong>{{ $fmt($ev['baseline_mae']) }}</strong>
            <span class="status {{ $ev['beats_baseline'] ? 'high' : 'low' }}" style="color:#fff">{{ $ev['beats_baseline'] ? 'Model is better' : 'Model is NOT better — use with care' }}</span></div>
        <div class="stat"><span>Trend</span><strong>{{ ($m['slope_per_period'] >= 0 ? '+' : '').$fmt($m['slope_per_period']) }}</strong><span>per {{ $granularity }} · R² {{ $m['r2'] }}</span></div>
    </section>

    <div class="card" style="max-width:none;overflow-x:auto">
        <h2>History and forecast</h2>
        <svg viewBox="0 0 {{ $w }} {{ $h + 20 }}" width="100%" role="img" aria-label="Actual sales line followed by the forecast line with a shaded range">
            @if ($band)<polygon points="{{ $band }}" fill="#E7B96E" fill-opacity=".35" />@endif
            <polyline points="{{ $actualPts }}" fill="none" stroke="#6B4220" stroke-width="2" />
            <polyline points="{{ $fcPts }}" fill="none" stroke="#2C6E9B" stroke-width="2" stroke-dasharray="6 4" />
            <text x="0" y="{{ $h + 16 }}" font-size="11" fill="#6B4220">{{ $series->first()['period'] }}</text>
            <text x="{{ $w }}" y="{{ $h + 16 }}" font-size="11" fill="#6B4220" text-anchor="end">{{ $series->last()['period'] }}</text>
        </svg>
        <p class="muted">Brown: actual. Blue dashed: forecast. Shaded: approximate range. Model: {{ $m['type'] }}, learned from {{ $result['train_from'] }} to {{ $result['train_to'] }} ({{ $result['observed_periods'] }} {{ $granularity }}s with sales).</p>
    </div>

    <div class="grid-4" style="grid-template-columns:repeat(auto-fit,minmax(22rem,1fr))">
        <div class="card" style="max-width:none;overflow-x:auto"><h2>Forecast</h2>
            <table class="table"><thead><tr><th>{{ $granularity === 'day' ? 'Day' : 'Week of' }}</th><th>Expected</th><th>Range</th></tr></thead><tbody>
            @foreach ($result['forecast'] as $f)
                <tr><td>{{ \Carbon\Carbon::parse($f['period'])->format($granularity === 'day' ? 'D, M j' : 'M j') }}</td><td><strong>{{ $fmt($f['predicted']) }}</strong></td><td class="muted">{{ $fmt($f['lower']) }} – {{ $fmt($f['upper']) }}</td></tr>
            @endforeach
            </tbody></table>
            <form method="POST" action="{{ route('reports.forecast.save') }}" style="margin-top:1rem">@csrf
                <input type="hidden" name="branch" value="{{ $branchId }}"><input type="hidden" name="variant" value="{{ $variantId }}">
                <input type="hidden" name="metric" value="{{ $metric }}"><input type="hidden" name="granularity" value="{{ $granularity }}">
                <input type="hidden" name="horizon" value="{{ $horizon }}"><input type="hidden" name="train_from" value="{{ $trainFrom }}"><input type="hidden" name="train_to" value="{{ $trainTo }}">
                <button class="btn-outline" style="padding:.4rem 1rem" type="submit">Save to compare with real sales later</button>
            </form></div>
        <div class="card" style="max-width:none;overflow-x:auto"><h2>How it did on the held-out {{ $granularity }}s</h2>
            <table class="table"><thead><tr><th>{{ $granularity === 'day' ? 'Day' : 'Week of' }}</th><th>Actual</th><th>Predicted</th></tr></thead><tbody>
            @foreach ($ev['points'] as $p)
                <tr><td>{{ \Carbon\Carbon::parse($p['period'])->format('D, M j') }}</td><td>{{ $fmt($p['actual']) }}</td><td>{{ $fmt($p['predicted']) }}</td></tr>
            @endforeach
            </tbody></table></div>
    </div>

    <div class="card" style="max-width:none"><h2>Limits</h2><ul class="muted">@foreach ($result['notes'] as $note)<li>{{ $note }}</li>@endforeach</ul></div>
@endif
@endsection
