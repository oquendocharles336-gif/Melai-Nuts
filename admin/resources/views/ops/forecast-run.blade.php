@extends('layouts.panel')
@section('title', 'Saved Forecast · Melai Nuts Admin')
@section('page-title', 'Saved Forecast')
@section('panel')
@php $fmt = fn ($n) => $n === null ? '—' : ($run['metric'] === 'revenue' ? \App\Support\Format::peso($n) : number_format((float) $n, 1)); @endphp
@include('partials.flash')

<section class="stat-row">
    <div class="stat"><span>Saved</span><strong style="font-size:1.1rem">{{ \Carbon\Carbon::parse($run['created_at'])->setTimezone(config('app.timezone'))->format('M j, Y g:i A') }}</strong></div>
    <div class="stat"><span>{{ $run['granularity'] === 'day' ? 'Days' : 'Weeks' }} with actual sales so far</span><strong>{{ $run['periods_with_actuals'] }}</strong></div>
    <div class="stat"><span>Real error so far (MAE)</span><strong>{{ $fmt($run['mae']) }}</strong>
        <span>error when saved: {{ $fmt($run['evaluation_at_creation']['mae'] ?? null) }}</span></div>
    <div class="stat"><span>Actual inside the range</span><strong>{{ $run['within_range'] }} / {{ $run['periods_with_actuals'] }}</strong></div>
</section>

<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>{{ $run['granularity'] === 'day' ? 'Day' : 'Week of' }}</th><th>Predicted</th><th>Range</th><th>Actual</th><th>Difference</th></tr></thead>
        <tbody>
        @foreach ($run['points'] ?? [] as $p)
            <tr><td>{{ \Carbon\Carbon::parse($p['period'])->format('D, M j') }}</td><td>{{ $fmt($p['predicted']) }}</td>
                <td class="muted">{{ $fmt($p['lower']) }} – {{ $fmt($p['upper']) }}</td>
                <td>{{ $p['actual'] === null ? 'not yet' : $fmt($p['actual']) }}</td>
                <td>{{ $p['actual'] === null ? '' : $fmt($p['actual'] - $p['predicted']) }}</td></tr>
        @endforeach
        </tbody>
    </table>
</div>
<p><a class="link" href="{{ route('reports.forecast') }}">Run a new forecast</a></p>
@endsection
