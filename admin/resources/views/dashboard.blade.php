@extends('layouts.panel')
@section('title', 'Overview · Melai Nuts Admin')
@section('page-title', 'Overview')
@section('page-sub', 'What is selling, what is running low, and what is still on the bench.')
@section('page-actions')
    <x-button icon="download" x-on:click="$dispatch('overview-export')">Export</x-button>
    <x-button variant="primary" icon="plus" x-on:click="$dispatch('open-modal', 'new-order')">New order</x-button>
@endsection
@section('panel')
@php $label = ['low' => 'Low', 'average' => 'Average', 'high' => 'High', 'normal' => 'Normal', 'plenty' => 'Plenty', 'none' => 'No data', 'unrated' => 'Not rated'];
     $int = fn ($n) => $n === null ? '—' : number_format($n); $rate = fn ($n) => $n === null ? '—' : number_format($n * 100, 1).'%';
     $periodLabel = ['today' => 'today', 'week' => 'this week', 'month' => 'this month'][$period];
     $scopeLabel = $branchId ? (collect($branches)->first()['name'] ?? '') : (count($allBranches) > 1 ? 'all branches' : (collect($allBranches)->first()['name'] ?? ''));
     $q = fn (array $o) => '?'.http_build_query(array_filter(array_merge(['period' => $period, 'branch' => $branchId], $o), fn ($v) => $v !== null));
     $tone = ['low' => 'bad', 'average' => 'warn', 'normal' => 'warn', 'high' => 'ok', 'plenty' => 'ok', 'none' => 'info', 'info' => 'info', 'unrated' => 'info']; @endphp

@include('partials.flash')

{{-- ===================== Live overview (range-aware JSON: /dashboard/overview.json) ===================== --}}
<div id="overview-live" data-keep="range,branch,filter,page" x-data="overview({ url: @js(route('dashboard.overview')), range: 30, branch: @js($branchId) })" x-on:overview-export.window="exportCsv()"
     :class="loading && 'is-loading'" class="grid" style="gap:16px">

    @if (count($allBranches) > 1)
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
            <label class="muted" for="ov-branch" style="font-size:13px">Showing</label>
            <select id="ov-branch" class="select" style="width:auto;height:32px;font-size:13px" x-model="branch" x-on:change="load()">
                <option value="">All branches</option>
                @foreach ($allBranches as $b)<option value="{{ $b['id'] }}">{{ $b['name'] }}</option>@endforeach
            </select>
            <span class="muted" style="font-size:12.5px" x-show="data" x-text="'Updated ' + $ago(data?.updatedAt)"></span>
        </div>
    @endif

    <div class="ov-top stagger">
        {{-- Revenue --}}
        <x-card title="Revenue" subtitle="Net sales: after discounts and completed refunds, all channels">
            <x-slot:actions>
                <x-segmented :options="[7 => '7 days', 30 => '30 days', 90 => '90 days']" model="range" change="setRange" label="Revenue range" />
            </x-slot:actions>
            <div class="blur-in">
                <div class="kpi-value xl" style="margin-top:0" :class="!data && 'skel'" x-count.peso="rev.total">—</div>
                <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-height:20px">
                    <span class="delta" :class="deltaClass(rev.delta)" x-text="deltaText(rev.delta)"></span>
                    <span class="delta-note" x-show="rev.delta !== null" x-text="'vs the ' + range + ' days before'"></span>
                </div>
                <div class="delta-note" data-revenue-breakdown x-show="data && rev.gross !== null && rev.gross !== undefined"
                     x-text="'Gross ' + $peso(rev.gross, true) + ' · refunds ' + $peso(rev.refunds, true) + ' (' + (rev.refundCount ?? 0) + ')' + (rev.refundRate !== null && rev.refundRate !== undefined ? ' · refund rate ' + (rev.refundRate * 100).toFixed(1) + '%' : '') + (rev.pendingRefunds ? ' · ' + $peso(rev.pendingRefunds, true) + ' pending, not deducted' : '')"></div>
                <div class="delta-note" x-show="data && data.salesAvailable === false">Sales figures need supabase/migrations/20261015000000_refunds_in_analytics.sql.</div>
                <div style="margin-top:14px"><x-chart-line data="rev.series" :height="250" label="Daily net revenue" /></div>
            </div>
        </x-card>

        {{-- KPI 2×2 --}}
        <div class="kpi-grid">
            <x-kpi label="Orders" icon="orders" :href="route('orders.index')" x-value="k.orders?.value ?? null" x-delta="k.orders?.delta ?? null" x-spark="k.orders?.spark" loading="!data" delta-note="vs before" />
            <x-kpi label="Items sold" icon="stock" :href="route('section', 'sales')" x-value="k.items?.value ?? null" x-delta="k.items?.delta ?? null" x-spark="k.items?.spark" loading="!data" delta-note="vs before" />
            <x-card :href="route('section', 'inventory')">
                <div class="kpi-top"><span class="icon-chip accent"><x-icon name="alert" :size="16" /></span>Running low</div>
                <div class="kpi-value" :class="!data && 'skel'" x-count.int="k.low?.value ?? null">—</div>
                <span class="delta-note" x-show="data" x-text="k.low?.out ? k.low.out + ' out of stock' : 'Nothing out of stock'"></span>
                <ul class="low-list">
                    <template x-for="i in (k.low?.items || [])" :key="i.name"><li><span x-text="i.name"></span><b x-text="i.qty <= 0 ? 'Out' : i.qty + ' left'"></b></li></template>
                </ul>
            </x-card>
            <x-kpi label="Average order" icon="coins" :href="route('section', 'sales')" x-value="k.average?.value ?? null" format="peso" x-delta="k.average?.delta ?? null" x-spark="k.average?.spark" loading="!data" delta-note="vs before" />
        </div>
    </div>

    <div class="ov-mid stagger">
        {{-- Order pipeline --}}
        <x-card title="Order pipeline" subtitle="Orders placed in the selected range, by stage">
            <div class="pipe" role="img" :aria-label="`New ${pipe.counts.new}, Packing ${pipe.counts.packing}, Shipped ${pipe.counts.shipped}, Delivered ${pipe.counts.delivered}`">
                <span class="s-new" :style="'flex-grow:' + pipeFlex('new')"></span><span class="s-packing" :style="'flex-grow:' + pipeFlex('packing')"></span>
                <span class="s-shipped" :style="'flex-grow:' + pipeFlex('shipped')"></span><span class="s-delivered" :style="'flex-grow:' + pipeFlex('delivered')"></span>
            </div>
            <div class="pipe-legend">
                <div><i style="background:var(--surface-3)"></i>New<b x-count.int="pipe.counts.new">0</b></div>
                <div><i style="background:var(--accent)"></i>Packing<b x-count.int="pipe.counts.packing">0</b></div>
                <div><i style="background:var(--accent-strong)"></i>Shipped<b x-count.int="pipe.counts.shipped">0</b></div>
                <div><i style="background:var(--ink)"></i>Delivered<b x-count.int="pipe.counts.delivered">0</b></div>
            </div>
            <p class="note" x-show="data" x-text="(pipe.returned === 1 ? '1 return requested' : pipe.returned + ' returns requested') + ' this week' + (pipe.cancelled ? ' · ' + pipe.cancelled + ' cancelled in range' : '')"></p>
        </x-card>

        {{-- Revenue by channel --}}
        <x-card title="Revenue by channel" subtitle="Net sales: confirmed payments, after discounts and refunds">
            <div class="hbars">
                <template x-for="c in (data?.channels || [])" :key="c.key">
                    <div class="hbar-row"><div class="top"><span x-text="c.label + ' · ' + c.orders + (c.orders === 1 ? ' order' : ' orders')"></span><span x-text="$peso(c.amount, true)"></span></div>
                        <div class="progress thin"><span :style="'width:' + Math.max(0, c.amount) / channelMax * 100 + '%'"></span></div></div>
                </template>
                <template x-if="!data"><div class="grid" style="gap:14px"><div class="skel" style="height:28px"></div><div class="skel" style="height:28px"></div><div class="skel" style="height:28px"></div></div></template>
            </div>
            <div class="note" x-show="data?.payments?.length" x-text="'By method: ' + (data?.payments || []).map(p => p.label + ' ' + $peso(p.amount, true)).join(' · ')"></div>
        </x-card>

        {{-- Top sellers --}}
        <x-card title="Top sellers">
            <x-slot:actions><a class="link" href="{{ route('section', 'products') }}" style="font-size:13px">Catalogue</a></x-slot:actions>
            <ol class="rank">
                <template x-for="(t, i) in (data?.top || [])" :key="t.name">
                    <li><span class="pos" x-text="i + 1"></span><span class="name" x-text="t.name"></span>
                        <span class="val" x-text="t.units + ' units · ' + t.share + '%'"></span>
                        <div class="progress thin"><span :style="'width:' + t.bar + '%'"></span></div></li>
                </template>
            </ol>
            <p class="empty" x-show="data && !data.top.length">No paid orders in this range yet.</p>
            <p class="note" x-show="data?.top?.length">Units sold minus units refunded; share of net product sales in the range.</p>
        </x-card>
    </div>

    {{-- Recent activity --}}
    <x-card title="Recent activity" subtitle="Orders, stock changes and supplier receipts, newest first" flush>
        <x-slot:actions>
            <div class="chips" role="group" aria-label="Filter activity">
                @foreach (['all' => 'All', 'orders' => 'Orders', 'stock' => 'Stock', 'suppliers' => 'Suppliers'] as $k => $v)
                    <button type="button" class="chip" :class="filter === '{{ $k }}' && 'is-on'" x-on:click="filter = '{{ $k }}'" :aria-pressed="filter === '{{ $k }}'">{{ $v }}</button>
                @endforeach
            </div>
        </x-slot:actions>
        <x-table stack>
            <x-slot:head><th>When</th><th>What happened</th><th>Area</th><th>By</th><th>Status</th></x-slot:head>
            <template x-for="(a, i) in pageRows" :key="i + a.when + a.what">
                <tr class="is-click" x-on:click="a.href && (window.location.href = a.href)">
                    <td class="cell-sub" style="white-space:nowrap" x-text="$ago(a.when)" :title="$datetime(a.when)"></td>
                    <td class="cell-strong" x-text="a.what"></td>
                    <td data-label="Area" style="text-transform:capitalize" x-text="a.area"></td>
                    <td><span class="who"><span class="avatar sm" x-text="$initials(a.by)"></span><span x-text="a.by"></span></span></td>
                    <td><span class="badge" :class="a.tone" x-text="a.status"></span></td>
                </tr>
            </template>
            <tr x-show="!loading && !activity.length"><td colspan="5" class="empty">Nothing here yet.</td></tr>
            <template x-if="!data"><tr><td colspan="5"><div class="skel" style="height:120px"></div></td></tr></template>
        </x-table>
        <x-pager-alpine list="activity" />
    </x-card>
</div>

{{-- ===================== Branches and staff (server-rendered, updated live) ===================== --}}
<div class="section-title"><h2>Branches &amp; team</h2><p>Per-branch sales, stock and staff</p></div>

<div id="live-dashboard" class="stack">
<section class="block">
    <div class="block-head">
        <h2>Overview {{ $periodLabel }} · {{ $scopeLabel }}</h2>
        <div style="display:flex;flex-wrap:wrap;gap:.75rem;align-items:center">
            @if (count($allBranches) > 1)
                <form method="GET" data-branch-filter style="display:flex;gap:8px;align-items:center">
                    <input type="hidden" name="period" value="{{ $period }}">
                    <label class="muted" for="branch-filter" style="font-size:13px">Branch</label>
                    <select class="select" id="branch-filter" name="branch" onchange="this.form.requestSubmit()" style="width:auto;height:32px;font-size:13px">
                        <option value="" @selected(! $branchId)>All branches</option>
                        @foreach ($allBranches as $b)<option value="{{ $b['id'] }}" @selected($branchId === $b['id'])>{{ $b['name'] }}</option>@endforeach
                    </select>
                    <noscript><button class="btn sm" type="submit">Show</button></noscript>
                </form>
            @endif
            <div class="tabs">@foreach (['today' => 'Today', 'week' => 'This week', 'month' => 'This month'] as $k => $v)
                <a data-soft href="{{ $q(['period' => $k]) }}" class="{{ $period === $k ? 'active' : '' }}">{{ $v }}</a>@endforeach</div>
        </div>
    </div>
    @if ($period !== 'today')
    <section class="stat-row">
        <div class="stat"><span>Net sales today</span><strong>{{ $peso($today['net_sales']) }}</strong></div>
        <div class="stat"><span>Refunds today ({{ $int($today['refund_count']) }})</span><strong>{{ $peso($today['refunds']) }}</strong></div>
        <div class="stat"><span>Paid orders today</span><strong>{{ $int($today['paid_orders']) }}</strong></div>
        <div class="stat"><span>Orders placed today</span><strong>{{ number_format($today['orders']) }}</strong></div>
    </section>
    @endif
    <section class="stat-row" data-sales-figures>
        <div class="stat"><span>Net sales</span><strong>{{ $peso($kpis['net_sales']) }}</strong></div>
        <div class="stat"><span>Gross paid sales</span><strong>{{ $peso($kpis['gross_sales']) }}</strong></div>
        <div class="stat"><span>Discounts</span><strong>{{ $peso($kpis['discounts']) }}</strong></div>
        <div class="stat"><span>Refunded ({{ $int($kpis['refund_count']) }})</span><strong>{{ $peso($kpis['refunds']) }}</strong></div>
        <div class="stat"><span>Refund rate</span><strong>{{ $rate($kpis['refund_rate']) }}</strong></div>
        <div class="stat"><span>Average order value</span><strong>{{ $peso($kpis['average_order_value']) }}</strong></div>
    </section>
    <section class="stat-row">
        <div class="stat"><span>Orders placed</span><strong>{{ number_format($kpis['orders']) }}</strong></div>
        <div class="stat"><span>Paid orders</span><strong>{{ $int($kpis['paid_orders']) }}</strong></div>
        <div class="stat"><span>Customers who ordered</span><strong>{{ number_format($kpis['customers']) }}</strong></div>
        <div class="stat"><span>Unpaid / failed payments</span><strong>{{ number_format($kpis['payments_pending']) }} / {{ number_format($kpis['payments_failed']) }}</strong></div>
    </section>
    @unless ($kpis['sales_available'])
        <p class="note"><strong>Sales figures need the database function sales_overview:</strong> run supabase/migrations/20261015000000_refunds_in_analytics.sql. Until then they are shown as "—" (nothing is calculated here).</p>
    @endunless
    @if ($kpis['orders'] === 0 && ! $kpis['paid_orders'] && ! $kpis['refund_count'])
        <p class="muted">No orders recorded {{ $periodLabel }}.</p>
    @else
        <div class="cols-2">
            <div class="card-b">
                <div class="card-top"><strong>Orders by status</strong></div>
                @forelse ($kpis['statuses'] as $st)
                    <div class="muted" style="display:flex;justify-content:space-between;padding:3px 0"><span>{{ $st['label'] }}</span><strong class="tabular" style="color:var(--ink)">{{ number_format($st['count']) }}</strong></div>
                @empty <div class="muted">No orders placed {{ $periodLabel }}.</div> @endforelse
            </div>
            <div class="card-b">
                <div class="card-top"><strong>Net sales by payment method</strong></div>
                @forelse ($kpis['payment_methods'] as $m)
                    <div class="muted" style="display:flex;justify-content:space-between;padding:3px 0"><span>{{ $methodLabel($m['method']) }} ({{ $m['orders'] }}){{ $m['refunds'] > 0 ? ' · refunds '.$peso($m['refunds']) : '' }}</span><strong class="tabular" style="color:var(--ink)">{{ $peso($m['amount']) }}</strong></div>
                @empty <div class="muted">No sales recorded {{ $periodLabel }}.</div> @endforelse
            </div>
        </div>
    @endif
    <p class="note">Gross sales = orders with a confirmed payment placed {{ $periodLabel }} (before discounts, without delivery fees); pending, failed and cancelled orders are not revenue. Refunds count on the day they were completed, partial refunds included. Net = gross − discounts − refunds, the same figure as in the app. Refunds still being reviewed are shown under "Pending refunds" and are not deducted yet.</p>
</section>

<section class="stat-row">
    <div class="stat"><span>Pending refunds (not deducted)</span><strong>{{ $int($pendingRefunds) }}</strong>@if ($pendingRefundAmount !== null)<span>{{ $peso($pendingRefundAmount) }}</span>@endif</div>
    <div class="stat"><span>Low / out of stock items</span><strong>{{ number_format($kpis['low_stock']) }} / {{ number_format($kpis['out_of_stock']) }}</strong></div>
    <div class="stat"><span>Active loyalty members</span><strong>{{ number_format($loyalty['members']) }}</strong></div>
</section>
<section class="stat-row">
    <div class="stat"><span>Points issued this month</span><strong>{{ number_format($loyalty['issued_month']) }}</strong></div>
    <div class="stat"><span>Points redeemed this month</span><strong>{{ number_format($loyalty['redeemed_month']) }}</strong></div>
    <div class="stat"><span>Points reversed by refunds this month</span><strong>{{ $int($loyalty['reversed_month'] ?? null) }}</strong></div>
</section>

@if (count($topBranches) || ($staff !== null && count($topStaff)))
<section class="block">
    <h2>Top performers {{ $periodLabel }}</h2>
    <div class="cols-2">
        @if (count($topBranches))
        <div class="card-b" data-top-branches>
            <div class="card-top"><strong>Top branches (net sales)</strong></div>
            @foreach ($topBranches as $i => $b)
                <div class="muted" style="display:flex;justify-content:space-between;padding:3px 0"><span>{{ $i + 1 }}. {{ $b['name'] }} ({{ $int($b['paid_orders']) }} paid)</span><strong class="tabular" style="color:var(--ink)">{{ $peso($b['net']) }}</strong></div>
            @endforeach
        </div>
        @endif
        @if ($staff !== null)
        <div class="card-b" data-top-staff>
            <div class="card-top"><strong>Top cashiers (POS net sales)</strong></div>
            @forelse ($topStaff as $i => $p)
                <div class="muted" style="display:flex;justify-content:space-between;padding:3px 0"><span>{{ $i + 1 }}. {{ $p['full_name'] ?: $p['email'] }}{{ $p['branch_name'] ? ' · '.$p['branch_name'] : '' }} ({{ $p['pos_transactions'] }})</span><strong class="tabular" style="color:var(--ink)">{{ $peso((float) $p['pos_net_sales']) }}</strong></div>
            @empty <div class="muted">No in-store sales {{ $periodLabel }}.</div> @endforelse
        </div>
        @endif
    </div>
</section>
@endif

@if ($staff !== null)
<section class="block" data-staff-overview>
    <h2>Staff accounts · {{ $scopeLabel }}</h2>
    <section class="stat-row">
        <div class="stat"><span>Staff accounts (active)</span><strong>{{ $staffSummary['accounts'] }} ({{ $staffSummary['active'] }})</strong></div>
        <div class="stat"><span>Open cash drawers now</span><strong>{{ $staffSummary['open_shifts'] ?? '—' }}</strong></div>
        <div class="stat"><span>POS transactions {{ $periodLabel }}</span><strong>{{ $staffSummary['pos_transactions'] === null ? '—' : number_format($staffSummary['pos_transactions']) }}</strong></div>
        <div class="stat"><span>POS net sales {{ $periodLabel }}</span><strong>{{ $peso($staffSummary['pos_net_sales']) }}</strong></div>
    </section>
    <div class="ui-card flush">
        <x-table>
            <x-slot:head><th>Name</th><th>Role</th><th>Branch</th><th>Status</th><th>POS sales</th><th>Refunds</th><th>Net</th><th>Shifts</th><th>Drawer</th><th>Last activity</th></x-slot:head>
            @forelse ($staff as $p)
                <tr><td><span class="who"><span class="avatar sm">{{ mb_strtoupper(mb_substr($p['full_name'] ?: $p['email'], 0, 1)) }}</span><span><span class="cell-strong">{{ $p['full_name'] ?: '—' }}</span><div class="cell-sub">{{ $p['email'] }}</div></span></span></td>
                    <td>{{ ucfirst($p['role']) }}</td><td>{{ $p['branch_name'] ?? ($p['role'] === 'owner' ? 'All branches' : '—') }}</td>
                    <td><x-badge :tone="$p['account_status'] === 'active' ? 'ok' : 'bad'">{{ ucfirst($p['account_status'] ?? 'unknown') }}</x-badge></td>
                    @if ($staffActivity)
                    <td class="num">{{ number_format($p['pos_transactions']) }} · {{ $peso((float) $p['pos_sales']) }}</td>
                    <td class="num">{{ $peso((float) $p['pos_refunds']) }}@if (isset($p['pos_refund_count']) && $p['pos_refund_count'] > 0) ({{ $p['pos_refund_count'] }})@endif</td>
                    <td class="num"><strong>{{ $peso((float) $p['pos_net_sales']) }}</strong></td>
                    <td class="num">{{ $p['shifts_opened'] }}</td><td>{{ $p['open_shift'] ? 'Open' : '—' }}</td>
                    @else <td>—</td><td>—</td><td>—</td><td>—</td><td>—</td> @endif
                    <td class="cell-sub">{{ $p['last_activity_at'] ? \Carbon\Carbon::parse($p['last_activity_at'])->setTimezone(config('app.timezone'))->diffForHumans() : 'No activity yet' }}</td></tr>
            @empty
                <tr><td colspan="10" class="empty">No staff accounts in the app's staff registry yet.</td></tr>
            @endforelse
        </x-table>
    </div>
    @unless ($staffActivity) <p class="note"><strong>Sales per cashier, shifts and last activity need the database function owner_staff_overview:</strong> run supabase/migrations/20261013000000_admin_portal_owner_overview.sql. Until then only the staff list is shown (no numbers are guessed).</p> @endunless
    <p class="note">Every staff and owner account in the Melai Nuts app (staff_members). POS sales are in-store sales each cashier rang up with a confirmed payment, after discounts; refunds of those sales count against the cashier who made the sale, on the day they completed; net = POS sales − refunds. Last activity = latest POS sale, cash drawer shift or stock movement. Per-day drawer details: <a class="link" href="{{ route('section', 'cash-drawer') }}">Cash Drawer</a>.</p>
</section>
@endif

<section class="block">
    <h2>Sales per branch {{ $periodLabel }}</h2>
    <div class="grid-4">
        @if (empty($sales)) <div class="muted">No branches are available to this account.</div> @endif
        @foreach ($sales as $s)
            <div class="card-b">
                <div class="card-top"><strong>{{ $s['name'] }}</strong>@if ($s['target'])<span class="status {{ $s['status'] }}">{{ $label[$s['status']] }}</span>@endif</div>
                <div class="big">{{ $peso($s['net']) }}</div>
                @if ($s['gross'] !== null)<div class="muted" style="font-size:12.5px">Gross {{ $peso($s['gross']) }} · refunds {{ $peso($s['refunds']) }}@if ($s['pending_refund_amount'] > 0) · {{ $peso($s['pending_refund_amount']) }} pending @endif</div>@endif
                @if ($s['target'])
                    <div class="muted" style="font-size:12.5px">{{ $s['pct'] }}% of {{ $pesoWhole($s['target']) }} target</div>
                    <div class="bar"><span class="{{ $s['status'] }}" style="width: {{ min(100, $s['pct'] / $maxPct * 100) }}%"></span></div>
                @else
                    <div class="muted" style="font-size:12.5px">No target set</div>
                @endif
            </div>
        @endforeach
    </div>
    <p class="note">Net sales: paid orders minus discounts and completed refunds{{ $liveData ? ' (live from the Melai Nuts app)' : ' (test data)' }}. Sales targets and the Low/Average/High rating are owner settings in Business settings; "Not rated" = rating ratios not set.@if (auth()->user()?->isAdmin()) <a href="{{ route('admin.business.index') }}">Open Business settings</a>@endif</p>
</section>

<section class="block">
    <h2>Stock levels per branch</h2>
    @if ($liveData) <p class="note" style="margin:0">Share of products above their restock threshold in each branch. "Not rated" = stock-health ratios not set in Business settings.</p> @endif
    <div class="grid-4">
        @foreach ($stock as $s)
            <div class="card-b {{ $s['lowest'] ? 'lowest' : '' }}">
                <div class="card-top"><strong>{{ $s['name'] }}</strong><span class="status {{ $s['status'] === 'none' ? 'info' : $s['status'] }}">{{ $s['status'] === 'low' ? 'Low stock' : $label[$s['status']] }}</span></div>
                <div class="big">{{ $s['pct'] === null ? '—' : $s['pct'].'%' }}</div>
                @if ($s['lowest']) <div class="flag">Lowest stock</div> @endif
                @if ($s['pct'] === null) <div class="muted">No inventory records available.</div>
                @else
                @forelse ($s['lowItems'] as $i) <div class="muted" style="font-size:12.5px">{{ $i['qty'] <= 0 ? 'Out of stock' : 'Running low' }}: {{ $i['product'] }} ({{ $i['qty'] }} left)</div>
                @empty <div class="muted" style="font-size:12.5px">No products running low.</div> @endforelse
                @endif
            </div>
        @endforeach
    </div>
</section>

<p class="note">This page updates by itself when orders, refunds or stock change (Settings &gt; Live refresh).</p>
</div>{{-- #live-dashboard --}}

{{-- Live updates: the pulse in resources/js/ui.js. --}}
@endsection
