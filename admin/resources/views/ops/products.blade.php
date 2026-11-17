@extends('layouts.panel')
@section('title', 'Products · Melai Nuts Admin')
@section('page-title', 'Products')
@php
    $canEditPhotos = (bool) auth()->user()?->isAdmin();
    $photoMax = \App\Services\Supabase\ProductPhotoStorage::MAX_PHOTOS;
    // id => {name, images}: the photos each product has now (products.images, main photo first).
    $photoRows = collect($products)->mapWithKeys(fn ($p) => [$p['id'] => [
        'name' => $p['name'],
        'images' => array_values(array_filter((array) ($p['images'] ?? []), 'is_string')),
    ]]);
@endphp
@section('panel')
@include('partials.flash')

<p class="muted">The catalog customers see in the Melai Nuts app. Prices and variants are edited in the app's product management screen. {{ $canEditPhotos ? 'Here you can hide or show a product and manage its photos (up to '.$photoMax.' each, shown to every customer in the app and the web shop).' : 'Here you can see each product and its photos.' }} Stock is the total across the branches you can see.</p>

<div id="products-page" x-data="productPhotos(@js($photoRows), {
        storeUrl: @js(route('ops.products.photos.store', '__ID__')),
        destroyUrl: @js(route('ops.products.photos.destroy', '__ID__')),
        orderUrl: @js(route('ops.products.photos.order', '__ID__')),
        max: {{ $photoMax }}, canEdit: @js($canEditPhotos),
     })">
<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Product</th><th>Photos</th><th>Category</th><th>Variants (price · stock)</th><th>Status</th><th></th></tr></thead>
        <tbody>
        @forelse ($products as $p)
            @php $imgs = $photoRows[$p['id']]['images'] ?? []; @endphp
            <tr>
                <td><strong>{{ $p['name'] }}</strong>@if ($p['is_featured']) <span class="status info">Featured</span>@endif<br><span class="muted">{{ $p['sku'] ?: '' }} {{ $p['unit'] ? '· per '.$p['unit'] : '' }}</span></td>
                <td class="pp-cell">
                    <div class="pp-strip">
                        {{-- Fixed slots, no <template>: the table keeps its pager (resources/js/pager.js). --}}
                        @for ($i = 0; $i < $photoMax; $i++)
                            <button type="button" @class(['pp-thumb', 'is-main' => $i === 0]) x-show="!!photosOf(@js($p['id']))[{{ $i }}]" @unless (isset($imgs[$i])) style="display:none" @endunless
                                    x-on:click="canEdit && openPhotos(@js($p['id']))" title="{{ $i === 0 ? 'Main photo' : 'Photo '.($i + 1) }}" aria-label="Photo {{ $i + 1 }} of {{ $p['name'] }}">
                                <img @isset($imgs[$i]) src="{{ $imgs[$i] }}" @endisset :src="photosOf(@js($p['id']))[{{ $i }}] || ''" alt="" loading="lazy" decoding="async">
                            </button>
                        @endfor
                        <span class="pp-none" @if ($imgs) style="display:none" @endif x-show="photosOf(@js($p['id'])).length === 0" title="No photo yet: the app shows the product's placeholder"><x-icon name="image" :size="15" /></span>
                    </div>
                    @if ($canEditPhotos)
                        <button type="button" class="btn-outline pp-open" x-on:click="openPhotos(@js($p['id']))"
                                x-text="photosOf(@js($p['id'])).length === 0 ? 'Add photo' : 'Photos ' + photosOf(@js($p['id'])).length + '/' + max">{{ $imgs ? 'Photos '.count($imgs).'/'.$photoMax : 'Add photo' }}</button>
                    @endif
                </td>
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
                        <form method="POST" action="{{ route('ops.products.toggle', $p['id']) }}" data-confirm="{{ $p['is_active'] ? 'Hide '.$p['name'].' from customers? Its order history is kept and you can show it again later.' : 'Show '.$p['name'].' to customers again?' }}" data-confirm-title="{{ $p['is_active'] ? 'Hide product?' : 'Show product?' }}" data-confirm-label="{{ $p['is_active'] ? 'Hide' : 'Show' }}" {{ $p['is_active'] ? '' : 'data-confirm-safe' }}>
                            @csrf <input type="hidden" name="active" value="{{ $p['is_active'] ? 0 : 1 }}">
                            <button class="btn-outline" type="submit" style="padding:.3rem .8rem">{{ $p['is_active'] ? 'Hide' : 'Show' }}</button>
                        </form>
                    @endif
                </td>
            </tr>
        @empty
            <tr><td colspan="6">No products yet. Add them in the app's product management screen.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>

@if ($canEditPhotos)
    {{-- Photos of one product: add (with preview), replace, make main, remove. Saved with "Save photos". --}}
    <x-modal name="product-photos" title="Product photos" wide>
        <div class="modal-body pp-body" x-on:dragover.prevent x-on:drop.prevent>
            <p class="pp-product" x-text="current ? current.name : ''"></p>
            <p class="form-hint">Up to <span x-text="max"></span> photos · JPG, JPEG, PNG or WEBP · 5 MB each. The first photo is the main photo on the product's card in the app; customers swipe through all of them on the product page. Large photos are resized before uploading.</p>

            <input type="file" id="pp-picker" class="sr-only" accept="image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp"
                   x-on:change="picked($event)" :multiple="!replacing" tabindex="-1" aria-hidden="true">

            <div class="pp-grid">
                <template x-for="(slot, i) in slots" :key="slot.key">
                    <div class="pp-slot" :class="{ 'is-pending': slot.pending, 'is-empty': slot.empty, 'is-drop': dropOn === slot.key, 'has-error': slot.error }"
                         x-on:dragenter.prevent="slot.empty && (dropOn = slot.key)" x-on:dragleave="dropOn === slot.key && (dropOn = null)"
                         x-on:drop.prevent="dropOn = null; slot.empty && dropped($event)">

                        {{-- Empty: pick or drop a photo --}}
                        <template x-if="slot.empty">
                            <button type="button" class="pp-add" x-on:click="pick()" :disabled="busy">
                                <x-icon name="image-plus" :size="26" />
                                <span class="pp-add-label">Add photo</span>
                                <span class="pp-add-hint">Click or drop an image here</span>
                            </button>
                        </template>

                        <template x-if="!slot.empty">
                            <div class="pp-photo">
                                <img :src="slot.src" alt="" decoding="async">
                                <span class="pp-badge" x-show="slot.main && !slot.pending">Main photo</span>
                                <span class="pp-badge pending" x-show="slot.pending && !slot.error" x-text="slot.replaces ? 'Replacement · not saved yet' : 'New · not saved yet'"></span>

                                {{-- Upload progress --}}
                                <div class="pp-progress" x-show="slot.uploading" role="progressbar" :aria-valuenow="slot.progress" aria-valuemin="0" aria-valuemax="100" aria-label="Upload progress">
                                    <span :style="'width:' + slot.progress + '%'"></span>
                                </div>

                                {{-- Remove: asked right on the photo --}}
                                <div class="pp-confirm" x-show="confirmKey === slot.key" x-transition.opacity>
                                    <p>Remove this photo? Customers stop seeing it right away.</p>
                                    <div>
                                        <button type="button" class="btn sm" x-on:click="confirmKey = null">Keep</button>
                                        <button type="button" class="btn sm danger-solid" x-on:click="remove(slot)" :disabled="busy">Remove</button>
                                    </div>
                                </div>
                            </div>
                        </template>

                        <p class="pp-error" x-show="slot.error" x-text="slot.error" role="alert"></p>

                        <div class="pp-actions" x-show="!slot.empty">
                            <template x-if="slot.pending">
                                <button type="button" class="btn sm ghost" x-on:click="discard(slot)" :disabled="slot.uploading">Cancel</button>
                            </template>
                            <template x-if="!slot.pending">
                                <span class="pp-actions-row">
                                    <button type="button" class="btn sm ghost" x-show="!slot.main" x-on:click="makeMain(slot)" :disabled="busy" title="Make this the main photo (shown first in the app)" aria-label="Make this the main photo"><x-icon name="star" :size="14" />Main</button>
                                    <button type="button" class="btn sm ghost" x-on:click="pick(slot)" :disabled="busy"><x-icon name="refresh" :size="14" />Replace</button>
                                    <button type="button" class="btn sm ghost icon danger pp-remove" x-on:click="confirmKey = slot.key" :disabled="busy" title="Remove photo" aria-label="Remove photo"><x-icon name="trash" :size="15" /></button>
                                </span>
                            </template>
                        </div>
                    </div>
                </template>
            </div>

            <p class="form-error" x-show="error" x-text="error" role="alert"></p>
        </div>
        <div class="modal-foot">
            <span class="pp-foot-note" x-show="pendingCount > 0" x-text="pendingCount === 1 ? '1 photo ready to save' : pendingCount + ' photos ready to save'"></span>
            <button type="button" class="btn" x-on:click="closePhotos()" :disabled="busy" x-text="pendingCount > 0 ? 'Cancel' : 'Close'">Close</button>
            <button type="button" class="btn primary" x-on:click="save()" :disabled="busy || pendingCount === 0" :class="busy && 'is-busy'"
                    x-text="busy ? 'Uploading…' : (pendingCount > 1 ? 'Save ' + pendingCount + ' photos' : 'Save photo')">Save photo</button>
        </div>
    </x-modal>
@endif
</div>
@endsection
