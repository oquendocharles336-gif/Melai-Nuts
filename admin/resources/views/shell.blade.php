@extends('layouts.panel')
{{-- Instant page shell (App\Http\Middleware\ShellFirst): no data, no database call. resources/js/ui.js
     loads the real content of this URL right away and swaps it in. --}}
@section('title', $title.' · Melai Nuts Admin')
@section('custom-head')
    <header class="page-head" data-shell>
        <div><h1 class="page-title">{{ $title }}</h1><p class="page-sub"><span class="skel" style="display:inline-block;width:320px;max-width:70vw;height:14px"></span></p></div>
    </header>
@endsection
@section('panel')
    <div class="shell-skeleton" aria-busy="true" aria-live="polite">
        <span class="sr-only">Loading {{ $title }}…</span>
        @if ($kind === 'dashboard')
            <div class="ov-top"><div class="ui-card skel" style="height:420px"></div><div class="kpi-grid">@for ($i = 0; $i < 4; $i++)<div class="ui-card skel" style="height:200px"></div>@endfor</div></div>
            <div class="ov-mid"><div class="ui-card skel" style="height:220px"></div><div class="ui-card skel" style="height:220px"></div><div class="ui-card skel" style="height:220px"></div></div>
        @else
            <div class="cols-4">@for ($i = 0; $i < 4; $i++)<div class="ui-card skel" style="height:130px"></div>@endfor</div>
            <div class="ui-card skel" style="height:{{ $kind === 'reports' ? 320 : 460 }}px"></div>
        @endif
        <p class="note shell-slow">Taking a while? <a class="link" href="{{ request()->fullUrlWithQuery(['full' => 1]) }}">Load the full page</a>.</p>
    </div>
@endsection
