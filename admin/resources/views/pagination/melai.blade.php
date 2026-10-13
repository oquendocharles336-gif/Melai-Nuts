{{-- Shared pager for every server-paginated list (Payments, Refunds, All users, Activity logs).
     The in-page lists (tables, Orders, Stock) draw the same markup from resources/js/ui.js.
     Links use the in-page navigation (data-soft); "Rows" is remembered in this browser. --}}
@php
    $sizes = \App\Support\ListTools::PAGE_SIZES;
    $from = $paginator->firstItem() ?? 0;
    $to = $paginator->lastItem() ?? 0;
    $current = $paginator->currentPage();
    $last = $paginator->lastPage();
    $sizeUrl = fn ($n) => request()->fullUrlWithQuery(['per_page' => $n, 'page' => null, 'fresh' => null, 'full' => null]);
@endphp
@if ($paginator->total() > $sizes[0])
<nav class="pager" aria-label="Pages" data-pager>
    <span class="pager-info">{{ number_format($from) }}–{{ number_format($to) }} of {{ number_format($paginator->total()) }}</span>
    <div class="pager-pages">
        @if ($paginator->onFirstPage())
            <span class="pager-btn" aria-disabled="true" aria-label="Previous page">‹</span>
        @else
            <a class="pager-btn" href="{{ $paginator->previousPageUrl() }}" rel="prev" aria-label="Previous page" data-soft data-keep-scroll>‹</a>
        @endif
        @foreach (\App\Support\ListTools::pageWindow($current, $last) as $n)
            @if ($n === null)
                <span class="pager-gap" aria-hidden="true">…</span>
            @elseif ($n === $current)
                <span class="pager-btn is-on" aria-current="page">{{ $n }}</span>
            @else
                <a class="pager-btn" href="{{ $paginator->url($n) }}" aria-label="Page {{ $n }}" data-soft data-keep-scroll>{{ $n }}</a>
            @endif
        @endforeach
        @if ($paginator->hasMorePages())
            <a class="pager-btn" href="{{ $paginator->nextPageUrl() }}" rel="next" aria-label="Next page" data-soft data-keep-scroll>›</a>
        @else
            <span class="pager-btn" aria-disabled="true" aria-label="Next page">›</span>
        @endif
    </div>
    <label class="pager-size">Rows
        <select class="select" data-pager-size aria-label="Rows per page">
            @foreach ($sizes as $n)<option value="{{ $n }}" data-url="{{ $sizeUrl($n) }}" @selected($n === $paginator->perPage())>{{ $n }}</option>@endforeach
        </select>
    </label>
</nav>
@endif
