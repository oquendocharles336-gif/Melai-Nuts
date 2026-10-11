@extends('layouts.panel')
@section('title', 'Products · Melai Nuts Admin')
@section('page-title', 'Products')
@section('panel')
@php $peso = fn ($n) => $n === null ? '—' : '₱'.number_format((float) $n, 2); @endphp
@include('partials.flash')

<p class="muted">The catalog customers see in the Melai Nuts app. Prices, variants and photos are edited in the app's product management screen; here you can hide or show a product. Stock is the total across the branches you can see.</p>

<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Product</th><th>Category</th><th>Variants (price · stock)</th><th>Status</th><th></th></tr></thead>
        <tbody>
        @forelse ($products as $p)
            <tr>
                <td><strong>{{ $p['name'] }}</strong>@if ($p['is_featured']) <span class="status info">Featured</span>@endif<br><span class="muted">{{ $p['sku'] ?: '' }} {{ $p['unit'] ? '· per '.$p['unit'] : '' }}</span></td>
                <td>{{ $p['category'] ?? '—' }}</td>
                <td>
                    @forelse ($p['variants'] as $v)
                        <div>{{ $v['label'] ?: 'Regular' }} · {{ $peso($v['price'] ?? $p['price']) }} · <span class="{{ $v['stock'] <= 0 ? 'status low' : '' }}">{{ $v['stock'] }} in stock</span></div>
                    @empty
                        <span class="muted">No variants</span>
                    @endforelse
                </td>
                <td><span class="status {{ $p['is_active'] ? 'high' : 'low' }}">{{ $p['is_active'] ? 'Available' : 'Hidden' }}</span></td>
                <td>
                    @if (auth()->user()->isAdmin())
                        <form method="POST" action="{{ route('ops.products.toggle', $p['id']) }}" onsubmit="return confirm('{{ $p['is_active'] ? 'Hide this product from customers?' : 'Show this product to customers?' }}')">
                            @csrf <input type="hidden" name="active" value="{{ $p['is_active'] ? 0 : 1 }}">
                            <button class="btn-outline" type="submit" style="padding:.3rem .8rem">{{ $p['is_active'] ? 'Hide' : 'Show' }}</button>
                        </form>
                    @endif
                </td>
            </tr>
        @empty
            <tr><td colspan="5">No products yet. Add them in the app's product management screen.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
@endsection
