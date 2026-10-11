{{-- The page itself (header + content). Rendered inside the full shell, or alone as a fragment for
     the in-page navigation (X-Melai-Fragment: 1, see App\Http\Middleware\ShellFirst). --}}
@hasSection('custom-head')
    @yield('custom-head')
@else
    <header class="page-head">
        <div>
            <h1 class="page-title">@yield('page-title') @if (! $live)<span class="test-pill" title="Automated tests only: fixture data">Test data</span>@endif</h1>
            @hasSection('page-sub')<p class="page-sub">@yield('page-sub')</p>@endif
        </div>
        @hasSection('page-actions')<div class="page-actions">@yield('page-actions')</div>@endif
    </header>
@endif
<div class="stack">@yield('panel')</div>
