{{-- Table shell: horizontal scroll on small screens; `stack` turns rows into stacked cards below 640px. --}}
@props(['stack' => false])
<div class="ui-table-wrap">
    <table {{ $attributes->class(['ui-table', 'stacked' => $stack]) }}>
        @isset($head)<thead><tr>{{ $head }}</tr></thead>@endisset
        <tbody>{{ $slot }}</tbody>
    </table>
</div>
