@extends('layouts.panel')
@section('title', 'Activity Logs · Melai Nuts Admin')
@section('page-title', 'Activity logs')
@section('page-sub', 'Sign-ins, approvals and admin actions on this website, plus the app\'s own staff audit log.')
@section('panel')
<form method="GET" class="card filter-row" role="search">
    <input class="light-input" type="search" name="q" value="{{ $q }}" placeholder="Action, user, details, IP" aria-label="Search activity logs" maxlength="100" style="min-width:16rem">
    <button class="btn-outline" type="submit" style="padding:.5rem 1rem">Search</button>
    @if ($q !== '')<a href="{{ route('admin.logs') }}" class="btn-outline" style="padding:.5rem 1rem">Clear</a>@endif
    <a class="btn-outline" style="padding:.5rem 1rem" href="{{ route('admin.logs.export', ['source' => 'website', 'q' => $q]) }}">Website log CSV</a>
    @if ($liveData)<a class="btn-outline" style="padding:.5rem 1rem" href="{{ route('admin.logs.export', ['source' => 'app', 'q' => $q, 'before' => $before]) }}">App audit log CSV (this page)</a>@endif
</form>
<x-card title="Admin website" flush>
    <x-table>
        <x-slot:head><th>When</th><th>User</th><th>Action</th><th>Details</th><th>IP</th></x-slot:head>
        @forelse ($logs as $log)
            <tr><td class="cell-sub" style="white-space:nowrap">{{ $log->created_at }}</td>
                <td>@if ($log->user)<span class="who"><span class="avatar sm">{{ mb_strtoupper(mb_substr($log->user->name, 0, 1)) }}</span>{{ $log->user->name }}</span>@else — @endif</td>
                <td><x-badge tone="neutral" :dot="false">{{ $log->action }}</x-badge></td><td>{{ $log->description }}</td><td class="cell-sub">{{ $log->ip_address }}</td></tr>
        @empty
            <tr><td colspan="5" class="empty">{{ $q !== '' ? 'Nothing matches "'.$q.'".' : 'No activity yet.' }}</td></tr>
        @endforelse
    </x-table>
    @if ($logs->hasPages())<div style="padding:12px 16px;border-top:1px solid var(--line)">{{ $logs->links() }}</div>@endif
</x-card>

@if ($liveData)
    <div class="section-title"><h2>Melai Nuts app (staff audit log)</h2>
        <p>Append-only record kept by the app's database: stock, products, refunds, loyalty and staff changes, whether made in the app or on this website. 100 per page{{ $q !== '' ? ', filtered by your search' : '' }}.</p></div>
    @if ($appLogsError)
        <div class="flash bad">Not available: {{ $appLogsError }}</div>
    @else
        <x-card flush>
            <x-table>
                <x-slot:head><th>When</th><th>Staff</th><th>Branch</th><th>Action</th><th>Record</th><th>Details</th></x-slot:head>
                @forelse ($appLogs as $l)
                    <tr><td class="cell-sub" style="white-space:nowrap">{{ \Carbon\Carbon::parse($l['created_at'])->setTimezone(config('app.timezone'))->format('Y-m-d H:i:s') }}</td>
                        <td>{{ $l['staff_name'] ?? $l['staff_email'] ?? '—' }}</td><td>{{ $l['branch_name'] ?? '—' }}</td>
                        <td><x-badge tone="neutral" :dot="false">{{ $l['action'] }}</x-badge></td><td>{{ $l['entity_type'] }} {{ $l['entity_id'] }}</td>
                        <td class="cell-sub" style="max-width:28rem;word-break:break-word">{{ json_encode($l['metadata'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) }}</td></tr>
                @empty
                    <tr><td colspan="6" class="empty">{{ $q !== '' ? 'Nothing on this page matches.' : 'No app activity yet.' }}</td></tr>
                @endforelse
            </x-table>
            <div style="padding:12px 16px;border-top:1px solid var(--line);display:flex;gap:8px">
                @if ($before)<a class="btn sm" href="{{ route('admin.logs', ['q' => $q]) }}">Newest</a>@endif
                @if ($olderCursor)<a class="btn sm" href="{{ route('admin.logs', ['q' => $q, 'before' => $olderCursor]) }}">Older entries</a>@endif
            </div>
        </x-card>
    @endif
@endif
@endsection
