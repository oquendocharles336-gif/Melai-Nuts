@extends('layouts.panel')
@section('title', 'Products · Melai Nuts Admin')
@section('page-title', 'Products')
@php
    $canEditPhotos = (bool) auth()->user()?->isAdmin();
    $photoMax = \App\Services\Supabase\ProductPhotoStorage::MAX_PHOTOS;
    // Checked now (no network) so the owner is told what to fix BEFORE choosing a photo.
    $photoBlocker = $canEditPhotos ? app(\App\Services\Supabase\ProductPhotoStorage::class)->blocker(auth()->user()) : null;
    $photoMaxBytes = \App\Services\Supabase\ProductPhotoStorage::uploadLimitBytes();
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
        maxBytes: {{ $photoMaxBytes }}, blocker: @js($photoBlocker),
     })">
@if ($canEditPhotos)
    {{-- Shown only when the page's photo script did not start (an old public/build): then nothing on this
         page can add a photo, so say how to fix it instead of leaving buttons that do nothing. --}}
    <p class="pp-stale" role="alert" x-cloak x-show="typeof openPhotos !== 'function'">
        The photo tools did not load: this website is serving an old copy of its page scripts. In the
        <code>admin</code> folder run <code>npm install</code> and <code>npm run build</code> (or close and re-open
        <code>start-admin.bat</code>), then reload this page.
    </p>
@endif
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
                            @if ($canEditPhotos)
                                <button type="button" @class(['pp-thumb', 'is-main' => $i === 0]) x-show="!!photosOf(@js($p['id']))[{{ $i }}]" @unless (isset($imgs[$i])) style="display:none" @endunless
                                        x-on:click="openPhotos(@js($p['id']))" title="{{ $i === 0 ? 'Main photo' : 'Photo '.($i + 1) }}" aria-label="Manage photos of {{ $p['name'] }} (photo {{ $i + 1 }}{{ $i === 0 ? ', main photo' : '' }})">
                                    <img @isset($imgs[$i]) src="{{ $imgs[$i] }}" @endisset :src="photosOf(@js($p['id']))[{{ $i }}] || ''" alt="" loading="lazy" decoding="async">
                                </button>
                            @else
                                <span @class(['pp-thumb', 'is-readonly', 'is-main' => $i === 0]) x-show="!!photosOf(@js($p['id']))[{{ $i }}]" @unless (isset($imgs[$i])) style="display:none" @endunless title="{{ $i === 0 ? 'Main photo' : 'Photo '.($i + 1) }}">
                                    <img @isset($imgs[$i]) src="{{ $imgs[$i] }}" @endisset :src="photosOf(@js($p['id']))[{{ $i }}] || ''" alt="Photo {{ $i + 1 }} of {{ $p['name'] }}" loading="lazy" decoding="async">
                                </span>
                            @endif
                        @endfor
                        @if ($canEditPhotos)
                            {{-- The empty holder is itself an "add photo" button for the owner. --}}
                            <button type="button" class="pp-none is-action" @if ($imgs) style="display:none" @endif x-show="photosOf(@js($p['id'])).length === 0"
                                    x-on:click="openPhotos(@js($p['id']))" title="Add a photo" aria-label="Add a photo to {{ $p['name'] }}"><x-icon name="image-plus" :size="16" /></button>
                        @else
                            <span class="pp-none" @if ($imgs) style="display:none" @endif x-show="photosOf(@js($p['id'])).length === 0" title="No photo yet: the app shows the product's placeholder" role="img" aria-label="No photo yet"><x-icon name="image" :size="15" /></span>
                        @endif
                    </div>
                    @if ($canEditPhotos)
                        <button type="button" class="btn-outline pp-open" x-on:click="openPhotos(@js($p['id']))" aria-label="Photos of {{ $p['name'] }}"
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
        <x-slot:heading>
            <span class="pp-head-name" x-text="current ? current.name : 'Product photos'">Product photos</span>
            <span class="pp-head-count" x-show="current" x-text="photoCountLabel"></span>
        </x-slot:heading>
        <div class="modal-body pp-body" x-on:dragover.prevent x-on:drop.prevent>
            <p class="form-hint">The first photo is the main photo on the product's card in the app and the web shop; customers swipe through all of them on the product page. Large photos are resized in your browser before uploading.</p>

            {{-- Something must be fixed first (no app sign-in, .env keys missing): say what, before any picking. --}}
            <div class="pp-blocked" role="alert" x-show="blocker">
                <x-icon name="shield" :size="16" />
                <p x-text="blocker"></p>
            </div>

            <input type="file" id="pp-picker" class="sr-only" accept="image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp"
                   x-on:change="picked($event)" :multiple="!replacing" tabindex="-1" aria-hidden="true">

            <div class="pp-grid">
                <template x-for="(slot, i) in slots" :key="slot.key">
                    <div class="pp-slot" :class="{ 'is-pending': slot.pending, 'is-empty': slot.empty, 'is-drop': dropOn === slot.key, 'has-error': slot.error }"
                         x-on:dragenter.prevent="slot.empty && (dropOn = slot.key)" x-on:dragleave="dropOn === slot.key && (dropOn = null)"
                         x-on:drop.prevent="dropOn = null; slot.empty && dropped($event)">

                        {{-- Empty: upload card (click, Enter / Space, or drop a photo) --}}
                        <template x-if="slot.empty">
                            <button type="button" class="pp-add" x-on:click="choose()" :disabled="busy || !!blocker"
                                    :aria-label="'Upload photo for ' + (current ? current.name : 'this product') + '. JPG, PNG or WEBP, up to 5 MB, ' + max + ' photos max.'">
                                <span class="pp-add-icon"><x-icon name="image-plus" :size="26" /></span>
                                <span class="pp-add-label">Upload photo</span>
                                <span class="pp-add-text">Drag a photo here or click to choose</span>
                                <span class="pp-add-hint">JPG, PNG or WEBP · up to 5 MB · <span x-text="max"></span> photos max</span>
                            </button>
                        </template>

                        <template x-if="!slot.empty">
                            <div class="pp-photo">
                                <img x-show="slot.src" :src="slot.src" :alt="(slot.main ? 'Main photo' : 'Photo ' + (i + 1)) + (current ? ' of ' + current.name : '')" decoding="async">
                                <span class="pp-badge" x-show="slot.main && !slot.pending">Main photo</span>
                                <span class="pp-badge pending" x-show="slot.pending && !slot.error" x-text="slot.replaces ? 'Replacement · not saved yet' : 'New · not saved yet'"></span>
                                <span class="pp-badge warn" x-show="slot.pending && !slot.error && slot.item?.warnings?.length" :title="(slot.item?.warnings || []).join(' ')">Check this photo</span>

                                {{-- Upload progress --}}
                                <div class="pp-progress" x-show="slot.uploading" role="progressbar" :aria-valuenow="slot.progress" aria-valuemin="0" aria-valuemax="100" aria-label="Upload progress">
                                    <span :style="'width:' + slot.progress + '%'"></span>
                                </div>

                                {{-- Remove: asked right on the photo --}}
                                <div class="pp-confirm" x-show="confirmKey === slot.key" x-transition.opacity>
                                    <p>Remove this photo? Customers stop seeing it right away, and the file is deleted from storage.</p>
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
                                    <button type="button" class="btn sm ghost" x-on:click="choose(slot)" :disabled="busy || !!blocker" :aria-label="'Replace photo ' + (i + 1)"><x-icon name="refresh" :size="14" />Replace</button>
                                    <button type="button" class="btn sm ghost icon danger pp-remove" x-on:click="confirmKey = slot.key" :disabled="busy" title="Remove photo" :aria-label="'Remove photo ' + (i + 1)"><x-icon name="trash" :size="15" /></button>
                                </span>
                            </template>
                        </div>
                    </div>
                </template>
            </div>

            <p class="pp-full" x-show="isFull && !error" x-text="'This product has ' + max + ' photos, the most it can have. Replace or remove one to add another.'"></p>
            <p class="form-error" x-show="error" x-text="error" role="alert"></p>

            {{-- The owner's "Allow" choice, reviewable here; Reset asks again next time. --}}
            <p class="pp-access">
                <x-icon name="image" :size="14" />
                <span><strong>Photo access:</strong> <span x-text="accessLabel"></span></span>
                <button type="button" class="pp-linkbtn" x-show="accessAllowed" x-on:click="resetAccess()">Reset</button>
                <a class="pp-linkbtn" href="{{ route('legal.privacy') }}#privacy-9" target="_blank" rel="noopener">Privacy Policy</a>
            </p>
        </div>
        <div class="modal-foot">
            <span class="pp-foot-note" x-show="pendingCount > 0" x-text="pendingCount === 1 ? '1 photo ready to save' : pendingCount + ' photos ready to save'"></span>
            <button type="button" class="btn" x-on:click="closePhotos()" :disabled="busy" x-text="pendingCount > 0 ? 'Cancel' : 'Close'">Close</button>
            <button type="button" class="btn primary" x-on:click="askSave()" :disabled="busy || pendingCount === 0" :class="busy && 'is-busy'"
                    x-text="busy ? 'Uploading…' : (pendingCount > 1 ? 'Save ' + pendingCount + ' photos' : 'Save photo')">Save photo</button>
        </div>

        {{-- "Are you sure?" step before saving: the owner sees exactly what customers will see, on which product. --}}
        <div class="pp-consent-wrap" x-show="saveConfirmOpen" x-transition.opacity x-cloak>
            <div class="pp-consent pp-saveconfirm" role="alertdialog" aria-modal="true" aria-labelledby="pp-save-title" aria-describedby="pp-save-text"
                 x-trap.noautofocus="saveConfirmOpen" x-on:keydown.escape.stop.prevent="cancelSave()">
                <h3 id="pp-save-title" x-text="ready.length === 1 ? 'Are you sure you want to save this photo?' : 'Are you sure you want to save these ' + ready.length + ' photos?'"></h3>
                <p id="pp-save-text">They will be shown on <strong x-text="current ? current.name : ''"></strong> to every customer in the app and the web shop right away. Check that each photo shows this product.</p>
                <ul class="pp-save-list">
                    <template x-for="p in ready" :key="p.key">
                        <li :class="p.warnings?.length && 'has-warning'">
                            <img :src="p.src" :alt="p.name">
                            <div>
                                <strong x-text="placeOf(p)"></strong>
                                <span class="pp-save-name" x-text="p.name"></span>
                                <template x-for="w in (p.warnings || [])" :key="w"><span class="pp-save-warn" x-text="w"></span></template>
                            </div>
                        </li>
                    </template>
                </ul>
                <p class="pp-save-note" x-show="warnedCount > 0" x-text="warnedCount === 1 ? '1 photo needs a second look. If it is the wrong photo, go back and cancel it.' : warnedCount + ' photos need a second look. If one is wrong, go back and cancel it.'"></p>
                <div class="pp-consent-actions">
                    <button type="button" class="btn" x-on:click="cancelSave()">Go back</button>
                    <button type="button" class="btn primary" x-ref="saveYes" x-on:click="confirmSave()" x-text="ready.length === 1 ? 'Yes, save photo' : 'Yes, save ' + ready.length + ' photos'">Yes, save</button>
                </div>
            </div>
        </div>

        {{-- "Allow" step: asked once per signed-in owner before the file picker first opens. --}}
        <div class="pp-consent-wrap" x-show="consentOpen" x-transition.opacity x-cloak>
            <div class="pp-consent" role="alertdialog" aria-modal="true" aria-labelledby="pp-consent-title" aria-describedby="pp-consent-text"
                 x-trap.noautofocus="consentOpen" x-on:keydown.escape.stop.prevent="notNow()">
                <h3 id="pp-consent-title">Allow Melai Nuts to access your photos?</h3>
                <div id="pp-consent-text">
                    <p>This website can only read the photo files <strong>you choose</strong> in the next window. It never sees your other files, folders or your device.</p>
                    <p>The photos you choose are uploaded to Melai Nuts storage and shown to customers in the Melai Nuts app and the web shop. Anyone with a photo's link can view it, so do not choose private or personal photos.</p>
                    <p>You can remove or replace them any time; removed photos are deleted from storage.</p>
                </div>
                <p class="pp-consent-link"><a class="link" href="{{ route('legal.privacy') }}#privacy-9" target="_blank" rel="noopener">Read the Privacy Policy</a></p>
                <div class="pp-consent-actions">
                    <button type="button" class="btn" x-on:click="notNow()">Not now</button>
                    <button type="button" class="btn primary" x-ref="allow" x-on:click="allowAccess()">Allow and choose photos</button>
                </div>
            </div>
        </div>
    </x-modal>
@endif
</div>
@endsection
