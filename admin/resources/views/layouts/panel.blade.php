@extends(request()->header('X-Melai-Fragment') === '1' ? 'layouts.fragment' : 'layouts.base')
@section('body-class', 'light-body panel-body')
@section('content')
@php
    $user = auth()->user();
    $isAdmin = (bool) $user?->isAdmin();
    $platform = app(\App\Services\Platform::class);
    $live = $platform->isSupabase();
    // [key, label, url, request pattern, icon, badge store key]. Admin-only items follow the
    // existing role middleware (role:admin): staff never see them.
    $groups = [
        'Operations' => array_values(array_filter([
            ['overview', 'Overview', route('dashboard'), 'dashboard', 'overview', null],
            ['orders', 'Orders', route('orders.index'), 'orders*', 'orders', 'orders'],
            ['stock', 'Stock', route('section', 'inventory'), 's/inventory', 'stock', 'low'],
            ['reports', 'Reports', route('section', 'reports'), 's/reports*', 'reports', null],
            ['sales', 'Sales', route('section', 'sales'), 's/sales', 'trending', null],
            $live ? ['forecast', 'Forecast', route('reports.forecast'), 'reports/forecast*', 'forecast', null] : null,
            ['cash-drawer', 'Cash drawer', route('section', 'cash-drawer'), 's/cash-drawer', 'banknote', null],
            $isAdmin ? ['payments', 'Payments', route('admin.payments.index'), 'admin/payments*', 'card', null] : null,
            $isAdmin ? ['refunds', 'Refunds', route('admin.refunds.index'), 'admin/refunds*', 'refund', 'refunds'] : null,
        ])),
        'Records' => array_values(array_filter([
            ['products', 'Products', route('section', 'products'), 's/products', 'products', null],
            ['customers', 'Customers / Loyalty', route('loyalty.index'), 'loyalty*', 'users', null],
            $live ? ['cards', 'Loyalty cards', route('cards.index'), 'cards*', 'id-card', null] : null,
            $live ? ['suppliers', 'Suppliers', route('suppliers.index'), 'suppliers*', 'store', null] : null,
            $live ? ['receiving', 'Receiving (OCR)', route('receipts.index'), 'receipts*', 'scan', null] : null,
            $isAdmin ? ['team', 'All users', route('admin.users.index'), 'admin/users*', 'shield', null] : null,
            $isAdmin ? ['logs', 'Activity logs', route('admin.logs'), 'admin/activity-logs*', 'scroll', null] : null,
        ])),
        'Account' => array_values(array_filter([
            ['settings', 'Settings', route('settings'), 'settings', 'settings', null],
            $isAdmin ? ['profit', 'Profit & stock value', route('admin.profit.index'), 'admin/profit*', 'coins', null] : null,
            $isAdmin ? ['business', 'Business settings', route('admin.business.index'), 'admin/business-settings*', 'store', null] : null,
            ['help', 'Help', route('help'), 'help', 'help', null],
        ])),
    ];
    $navJs = collect($groups)->flatMap(fn ($items, $g) => collect($items)->map(fn ($i) => ['key' => $i[0], 'label' => $i[1], 'url' => $i[2], 'group' => $g, 'icon' => $i[4]]))->values();
    // Branches for the New order form. The shell must never break a page (e.g. "database unreachable").
    // The New order form loads its branches when it opens: the shell itself makes no database call.
    $fragment = request()->header('X-Melai-Fragment') === '1';
    $activeKey = collect($groups)->flatten(1)->first(fn ($i) => request()->is($i[3]) && ! ($i[0] === 'reports' && request()->is('reports/forecast*')))[0] ?? null;
    $initials = collect(preg_split('/\s+/', trim($user?->name ?? '?')))->filter()->map(fn ($p) => mb_substr($p, 0, 1))->pipe(fn ($c) => mb_strtoupper($c->first().($c->count() > 1 ? $c->last() : '')));
    $flash = array_values(array_filter([
        session('status') ? ['message' => session('status'), 'tone' => 'ok'] : null,
        session('error') ? ['message' => session('error'), 'tone' => 'bad'] : null,
    ]));
@endphp
@if ($fragment)
<div data-fragment data-title="@yield('title', 'Melai Nuts Admin')" data-nav="{{ $activeKey }}">
@include('layouts._page')
</div>
@else
<script>window.MelaiNav = @json($navJs); window.MelaiFlash = @json($flash);</script>

<div class="app" data-app-shell x-data>
    {{-- ============ Sidebar ============ --}}
    <div class="scrim" x-show="$store.ui.nav" x-cloak x-on:click="$store.ui.nav = false" x-transition.opacity></div>
    <aside class="side" :class="$store.ui.nav && 'is-open'" aria-label="Main navigation" x-on:keydown.escape="$store.ui.nav = false">
        <a href="{{ route('dashboard') }}" class="side-brand"><span class="logo-chip">@include('partials.logo')</span> Melai Nuts</a>

        <button type="button" class="side-search" x-on:click="$store.ui.palette = true" aria-label="Search (Command K)">
            <x-icon name="search" :size="15" /> Search...<kbd>⌘K</kbd>
        </button>

        <nav class="side-nav">
            @foreach ($groups as $group => $items)
                <div class="side-group">
                    <div class="side-label">{{ $group }}</div>
                    @foreach ($items as [$key, $label, $url, $match, $icon, $badge])
                        @php $active = request()->is($match) && ! ($key === 'reports' && request()->is('reports/forecast*')); @endphp
                        <a href="{{ $url }}" data-key="{{ $key }}" class="nav-item {{ $active ? 'is-active' : '' }}" @if ($active) aria-current="page" @endif>
                            <x-icon :name="$icon" :size="17" /> <span>{{ $label }}</span>
                            @if ($badge === 'orders')
                                <span class="nav-count" x-show="$store.counts.orders > 0" x-cloak x-text="$store.counts.orders" aria-label="active orders"></span>
                            @elseif ($badge === 'low')
                                <span class="nav-count warn" x-show="$store.counts.low > 0" x-cloak x-text="$store.counts.low" aria-label="items running low"></span>
                            @elseif ($badge === 'refunds')
                                <span class="nav-count bad" x-show="$store.counts.refunds > 0" x-cloak x-text="$store.counts.refunds" aria-label="pending refunds"></span>
                            @endif
                        </a>
                    @endforeach
                </div>
            @endforeach
        </nav>

        {{-- Plan / usage card: this month's net sales against the sales target (config) or last month. --}}
        <a href="{{ route('section', 'reports') }}" class="plan-card" style="text-decoration:none;display:block" x-show="$store.counts.loaded" x-cloak>
            <div style="display:flex;justify-content:space-between;gap:8px"><strong x-text="($store.counts.month?.label || '') + ' sales'"></strong>
                <span class="tabular" x-text="$store.counts.month?.pct === null ? '' : $store.counts.month?.pct + '%'"></span></div>
            <div class="plan-bar"><span :style="'width:' + ($store.counts.month?.pct ?? 0) + '%'"></span></div>
            <div class="muted tabular" x-show="$store.counts.month?.goal" x-text="$peso($store.counts.month?.net, true) + ' of ' + $peso($store.counts.month?.goal, true) + ' ' + ($store.counts.month?.goalLabel === 'sales target' ? 'target' : '(last month)')"></div>
            <div class="muted" x-show="!$store.counts.month?.goal" x-text="$peso($store.counts.month?.net) + ' so far · no earlier month to compare'"></div>
        </a>

        <div class="user-row" x-data="{ menu: false }" x-on:click.outside="menu = false" x-on:keydown.escape="menu = false">
            <button type="button" class="user-btn" x-on:click="menu = !menu" :aria-expanded="menu" aria-haspopup="menu">
                <span class="avatar">{{ $initials }}</span>
                <span class="user-meta"><b>{{ $user?->name }}</b><span>{{ $isAdmin ? 'Admin' : 'Staff' }}{{ $live ? '' : ' · test data' }}</span></span>
                <x-icon name="chevrons" :size="15" style="margin-left:auto;color:var(--faint)" />
            </button>
            <div class="menu up" role="menu" x-show="menu" x-cloak x-transition.origin.bottom>
                <a href="{{ route('settings') }}" role="menuitem"><x-icon name="settings" :size="16" /> Settings</a>
                <a href="{{ route('help') }}" role="menuitem"><x-icon name="keyboard" :size="16" /> Shortcuts & help</a>
                <a href="{{ route('legal.terms') }}" role="menuitem"><x-icon name="scroll" :size="16" /> Terms and Conditions</a>
                <a href="{{ route('legal.privacy') }}" role="menuitem"><x-icon name="shield" :size="16" /> Privacy Policy</a>
                <form method="POST" action="{{ route('logout') }}">@csrf
                    <button type="submit" role="menuitem"><x-icon name="logout" :size="16" /> Logout</button></form>
            </div>
        </div>
    </aside>

    {{-- ============ Content ============ --}}
    <main class="main" id="main">
        <div class="mobile-bar">
            <button class="btn ghost icon" type="button" x-on:click="$store.ui.nav = true" aria-label="Open menu"><x-icon name="menu" /></button>
            <a href="{{ route('dashboard') }}" class="side-brand"><span class="logo-chip">@include('partials.logo')</span> Melai Nuts</a>
            <button class="btn ghost icon" type="button" style="margin-left:auto" x-on:click="$store.ui.palette = true" aria-label="Search"><x-icon name="search" /></button>
        </div>
        <div class="main-inner page-enter">
            @include('layouts._page')
        </div>
        <footer class="legal-footer muted" style="padding:1.5rem 0 .5rem;font-size:.8rem;text-align:center">
            <a class="link" href="{{ route('legal.terms') }}">Terms and Conditions</a> ·
            <a class="link" href="{{ route('legal.privacy') }}">Privacy Policy</a>
        </footer>
    </main>
</div>

{{-- ============ Command palette (⌘K) ============ --}}
<div x-data="palette" x-show="$store.ui.palette" x-cloak x-on:keydown.escape.window="$store.ui.palette = false">
    <div class="overlay" x-on:click="$store.ui.palette = false" x-transition.opacity></div>
    <div class="modal-wrap" x-on:click.self="$store.ui.palette = false">
        <div class="palette" role="dialog" aria-modal="true" aria-label="Search" x-trap="$store.ui.palette" x-transition:enter="t-pop-enter" x-transition:enter-start="t-pop-from">
            <div class="palette-input"><x-icon name="search" :size="17" />
                <input x-ref="input" x-model="q" x-on:keydown="key($event)" placeholder="Jump to a page, an order or a product…" aria-label="Search" autocomplete="off">
                <span class="spinner" x-show="busy" x-cloak></span><kbd class="kbd">Esc</kbd></div>
            <ul class="palette-list" role="listbox">
                <template x-for="[group, items] in groups" :key="group">
                    <li><div class="palette-group" x-text="group"></div>
                        <template x-for="r in items" :key="r.i + r.label">
                            <div class="palette-item" role="option" :class="active === r.i && 'is-on'" :aria-selected="active === r.i" x-on:mouseenter="active = r.i" x-on:click="go(r)">
                                <x-icon name="arrow-right" :size="15" /><span x-text="r.label"></span><small x-text="r.hint"></small></div>
                        </template></li>
                </template>
                <li class="palette-empty" x-show="!results.length && !busy">Nothing matches “<span x-text="q"></span>”.</li>
            </ul>
        </div>
    </div>
</div>

{{-- ============ New order (in-store sale through the app's POS function) ============ --}}
<span data-new-order hidden></span>
<x-modal name="new-order" title="New order" wide>
    <div x-data="newOrder({ branches: [], live: @js($live), branchesUrl: @js(route('orders.branches')), catalogUrl: @js(route('orders.catalog')), storeUrl: @js(route('orders.store')) })">
        <form x-on:submit.prevent="submit()">
            <div class="modal-body form-grid">
                <p class="note" style="margin:0">Records a walk-in sale exactly like the app's POS: stock is taken from the branch (first-expiry-first-out) and the payment is confirmed. Online orders are placed by customers in the app.</p>
                <template x-if="!live"><div class="flash bad">New orders need the Melai Nuts app database (this is test data).</div></template>
                <div class="form-grid two">
                    <div><label class="form-label" for="no-branch">Branch</label>
                        <select id="no-branch" class="select" x-model="branch"><template x-for="b in branches" :key="b.id"><option :value="b.id" x-text="b.name"></option></template></select></div>
                    <div><label class="form-label" for="no-pick">Add product</label>
                        <div style="display:flex;gap:6px">
                            <select id="no-pick" class="select" x-model="pick" x-on:change="add()" :disabled="!live || loadingCatalog">
                                <option value="" x-text="loadingCatalog ? 'Loading products…' : 'Choose a product'"></option>
                                <template x-for="c in catalog" :key="c.variant_id"><option :value="c.variant_id" :disabled="c.stock <= 0" x-text="c.name + ' · ' + $peso(c.price) + (c.stock <= 0 ? ' · out of stock' : ' · ' + c.stock + ' left')"></option></template>
                            </select></div></div>
                </div>
                <ul class="lines" x-show="lines.length" x-cloak>
                    <template x-for="(l, i) in lines" :key="l.variant_id">
                        <li style="align-items:center"><span style="flex:1;min-width:0" x-text="variant(l.variant_id)?.name"></span>
                            <input class="input" type="number" min="1" :max="variant(l.variant_id)?.stock" x-model.number="l.quantity" style="width:76px;height:32px" :aria-label="'Quantity of ' + variant(l.variant_id)?.name">
                            <span class="tabular" style="width:96px;text-align:right" x-text="$peso((variant(l.variant_id)?.price || 0) * (l.quantity || 0))"></span>
                            <button type="button" class="btn ghost sm icon" x-on:click="lines.splice(i, 1)" aria-label="Remove line"><x-icon name="x" :size="14" /></button></li>
                    </template>
                    <li><b>Total</b><b class="tabular" x-text="$peso(total)"></b></li>
                </ul>
                <div class="form-grid two">
                    <div><span class="form-label">Payment</span>
                        <x-segmented :options="['cash' => 'Cash', 'gcash' => 'GCash', 'card' => 'Card']" model="method" light label="Payment method" /></div>
                    <div x-show="method === 'cash'"><label class="form-label" for="no-cash">Cash received (optional)</label>
                        <input id="no-cash" class="input" type="number" min="0" step="0.01" x-model="cash" :placeholder="total ? total.toFixed(2) : ''"></div>
                    <div x-show="method !== 'cash'" x-cloak><label class="form-label" for="no-ref">Reference number</label>
                        <input id="no-ref" class="input" x-model="reference" maxlength="80" placeholder="From the terminal or wallet"></div>
                </div>
                <p class="form-error" x-show="error" x-text="error" role="alert"></p>
            </div>
            <div class="modal-foot">
                <button type="button" class="btn" x-on:click="$dispatch('close-modal', 'new-order')">Cancel</button>
                <button type="submit" class="btn primary" :class="busy && 'is-busy'" :disabled="!live || !lines.length"><span class="spinner" x-show="busy" x-cloak></span> Record order</button>
            </div>
        </form>
    </div>
</x-modal>

<x-confirm-modal />
<x-toast />
@endif
@endsection
