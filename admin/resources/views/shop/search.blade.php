@extends('layouts.shop')

@section('title', $categoryName ?? ($q !== '' ? 'Search' : 'All nuts'))

@section('content')
    <div class="s-section">
        <div class="s-section-head">
            <div>
                <h1 class="s-title">
                    @if ($q !== '') Results for “{{ $q }}” @elseif ($categoryName) {{ $categoryName }} @else All nuts @endif
                </h1>
                <p class="s-sub">{{ count($results) }} {{ \Illuminate\Support\Str::plural('product', count($results)) }}{{ $branch ? ' · stock at '.$branch['name'] : '' }}</p>
            </div>
            <form method="GET" action="{{ route('shop.search') }}" class="s-inline" aria-label="Sort">
                @if ($q !== '')<input type="hidden" name="q" value="{{ $q }}">@endif
                @if ($category)<input type="hidden" name="category" value="{{ $category }}">@endif
                <label for="sort" class="sr-only">Sort by</label>
                <select id="sort" name="sort" class="s-btn ghost sm" onchange="this.form.submit()">
                    <option value="popular" @selected($sort === 'popular')>Best sellers</option>
                    <option value="price_asc" @selected($sort === 'price_asc')>Price: low to high</option>
                    <option value="price_desc" @selected($sort === 'price_desc')>Price: high to low</option>
                    <option value="name" @selected($sort === 'name')>Name</option>
                </select>
                <noscript><button class="s-btn ghost sm">Sort</button></noscript>
            </form>
        </div>

        @if ($categories)
            <div class="s-chips" aria-label="Categories">
                <a href="{{ route('shop.search', array_filter(['q' => $q, 'sort' => $sort !== 'popular' ? $sort : null])) }}" @class(['s-chip', 'is-on' => ! $category])>All</a>
                @foreach ($categories as $c)
                    <a href="{{ route('shop.search', array_filter(['q' => $q, 'category' => $c['id'], 'sort' => $sort !== 'popular' ? $sort : null])) }}" @class(['s-chip', 'is-on' => $category === $c['id']])>{{ $c['name'] }} <small>{{ $c['product_count'] }}</small></a>
                @endforeach
            </div>
        @endif
    </div>

    @if ($error)
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="alert" :size="28" /></span>
            <h3>We couldn't load the products</h3>
            <p>{{ $error }}</p>
            <a href="{{ url()->current().'?'.http_build_query(request()->query()) }}" class="s-btn primary">Try again</a>
        </div>
    @elseif ($results === [])
        <div class="s-empty">
            <span class="s-empty-icon"><x-icon name="search" :size="28" /></span>
            <h3>No nuts match {{ $q !== '' ? '“'.$q.'”' : 'this category' }}</h3>
            <p>Try another word, or look through every category.</p>
            <a href="{{ route('shop.search') }}" class="s-btn primary">Clear search</a>
        </div>
    @else
        <div class="s-grid">
            @foreach ($results as $p)
                @include('shop.partials.card', ['p' => $p, 'branch' => $branch])
            @endforeach
        </div>
    @endif
@endsection
