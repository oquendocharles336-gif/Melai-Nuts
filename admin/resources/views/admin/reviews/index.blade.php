@extends('layouts.panel')
@section('title', 'Product reviews · Melai Nuts Admin')
@section('page-title', 'Product reviews')
@section('page-sub', 'Every rating and comment customers left on products, in the app and on the shop. Hidden reviews stay here but customers no longer see them.')
@section('panel')
@php
    $when = fn ($t) => $t ? \Carbon\Carbon::parse($t)->setTimezone(config('app.timezone')) : null;
    $keep = array_filter(['q' => $q, 'product' => $product, 'status' => $status !== 'all' ? $status : null, 'sort' => $sort !== 'newest' ? $sort : null]);
    $pageUrl = fn (int $p) => route('admin.reviews.index', $keep + ($p > 1 ? ['page' => $p] : []));
@endphp

@include('partials.flash')

<section class="stat-row" data-review-summary>
    <div class="stat"><span>Reviews</span><strong>{{ number_format((int) ($summary['total'] ?? 0)) }}</strong><span>{{ (int) ($summary['last_30_days'] ?? 0) }} in the last 30 days</span></div>
    <div class="stat"><span>Average rating (visible)</span><strong>{{ ($summary['average_rating'] ?? null) !== null ? number_format((float) $summary['average_rating'], 1).' ★' : '—' }}</strong></div>
    <div class="stat"><span>Hidden</span><strong>{{ (int) ($summary['hidden'] ?? 0) }}</strong><span>not shown to customers</span></div>
</section>

<form method="GET" action="{{ route('admin.reviews.index') }}" class="card filter-row" role="search">
    <select class="light-input" name="product" aria-label="Product" onchange="this.form.requestSubmit()">
        <option value="">All products</option>
        @foreach ($products as $p)
            <option value="{{ $p['id'] }}" @selected($product === $p['id'])>{{ $p['name'] }} ({{ $p['review_count'] }})</option>
        @endforeach
    </select>
    <select class="light-input" name="status" aria-label="Visibility" onchange="this.form.requestSubmit()">
        @foreach ($statuses as $value => $label)<option value="{{ $value }}" @selected($status === $value)>{{ $label }}</option>@endforeach
    </select>
    <select class="light-input" name="sort" aria-label="Sort" onchange="this.form.requestSubmit()">
        @foreach ($sorts as $value => $label)<option value="{{ $value }}" @selected($sort === $value)>{{ $label }}</option>@endforeach
    </select>
    <input class="light-input" type="search" name="q" value="{{ $q }}" placeholder="Product, customer or words in the comment" aria-label="Search reviews" maxlength="100" style="min-width:16rem">
    <button class="btn-outline" type="submit" style="padding:.5rem 1rem">Search</button>
    @if ($keep)<a href="{{ route('admin.reviews.index') }}" class="btn-outline" style="padding:.5rem 1rem">Clear</a>@endif
</form>

<x-card flush>
    <x-table data-no-paginate>
        <x-slot:head><th>Product</th><th>Customer</th><th>Rating</th><th>Comment</th><th>Date</th><th>Status</th><th><span class="sr-only">Actions</span></th></x-slot:head>
        @forelse ($reviews as $r)
            @php($created = $when($r['created_at'] ?? null))
            @php($edited = ($r['updated_at'] ?? null) && ($r['updated_at'] !== $r['created_at']) ? $when($r['updated_at']) : null)
            <tr data-review-row="{{ $r['id'] }}" @class(['is-muted' => $r['is_hidden']])>
                <td><strong>{{ $r['product_name'] }}</strong></td>
                <td>{{ $r['customer_name'] }}@if (! empty($r['customer_email']))<br><span class="cell-sub">{{ $r['customer_email'] }}</span>@endif</td>
                <td style="white-space:nowrap"><span aria-label="{{ $r['rating'] }} out of 5 stars" role="img" style="color:var(--honey-deep);letter-spacing:1px">{{ str_repeat('★', (int) $r['rating']) }}<span style="opacity:.25">{{ str_repeat('★', 5 - (int) $r['rating']) }}</span></span></td>
                <td style="max-width:28rem;white-space:pre-line;overflow-wrap:anywhere">{{ $r['comment'] !== '' ? $r['comment'] : '—' }}</td>
                <td class="cell-sub" style="white-space:nowrap">{{ $created?->format('M j, Y g:i A') }}@if ($edited)<br>edited {{ $edited->format('M j') }}@endif</td>
                <td>@if ($r['is_hidden'])<x-badge tone="warn">Hidden</x-badge>@else<x-badge tone="ok">Visible</x-badge>@endif</td>
                <td style="white-space:nowrap">
                    <div style="display:flex;gap:.4rem;justify-content:flex-end">
                        <form method="POST" action="{{ route('admin.reviews.moderate', $r['id']) }}">
                            @csrf
                            @foreach ($keep as $k => $v)<input type="hidden" name="{{ $k }}" value="{{ $v }}">@endforeach
                            <input type="hidden" name="action" value="{{ $r['is_hidden'] ? 'show' : 'hide' }}">
                            <button class="btn-outline" type="submit" style="padding:.3rem .8rem">{{ $r['is_hidden'] ? 'Show' : 'Hide' }}</button>
                        </form>
                        <form method="POST" action="{{ route('admin.reviews.moderate', $r['id']) }}"
                              data-confirm="Delete {{ $r['customer_name'] }}'s review of {{ $r['product_name'] }}? This cannot be undone. To keep it but stop showing it, use Hide." data-confirm-title="Delete this review?" data-confirm-label="Delete">
                            @csrf
                            @foreach ($keep as $k => $v)<input type="hidden" name="{{ $k }}" value="{{ $v }}">@endforeach
                            <input type="hidden" name="action" value="delete">
                            <button class="btn-outline" type="submit" style="padding:.3rem .8rem" aria-label="Delete this review"><x-icon name="trash" :size="15" /></button>
                        </form>
                    </div>
                </td>
            </tr>
        @empty
            <tr><td colspan="7" class="empty">{{ $keep ? 'No reviews match these filters.' : 'No customer reviews yet. They appear here as soon as a customer rates a product they received.' }}</td></tr>
        @endforelse
    </x-table>
    @if ($pages > 1)
        <nav aria-label="Pages" style="padding:12px 16px;border-top:1px solid var(--line);display:flex;gap:8px;align-items:center;flex-wrap:wrap">
            @if ($page > 1)<a class="btn sm" href="{{ $pageUrl($page - 1) }}" rel="prev">Previous</a>@endif
            <span class="muted">Page {{ $page }} of {{ $pages }} · {{ $total }} {{ \Illuminate\Support\Str::plural('review', $total) }}</span>
            @if ($page < $pages)<a class="btn sm" href="{{ $pageUrl($page + 1) }}" rel="next">Next</a>@endif
        </nav>
    @elseif ($total > 0)
        <p class="muted" style="padding:12px 16px;margin:0;border-top:1px solid var(--line)">{{ $total }} {{ \Illuminate\Support\Str::plural('review', $total) }}</p>
    @endif
</x-card>
<p class="muted">Hide keeps the review (and its rating) out of the shop and the app; Show puts it back. Delete removes it for good. Every change is saved in the activity logs. New reviews and special instructions with offensive words are refused automatically (list: moderation/blocked_words.json).</p>
@endsection
