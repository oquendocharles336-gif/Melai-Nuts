@extends('layouts.panel')
@section('title', 'Business settings · Melai Nuts Admin')
@section('page-title', 'Business settings')
@section('page-sub', 'Rules and branch details the app and this website use. Stored in the shared database; an empty field means "Not set".')
@section('panel')
@include('partials.flash')
@php
    $s = $settings ?? [];
    $pct = fn ($v) => $v === null ? null : rtrim(rtrim(number_format((float) $v * 100, 2, '.', ''), '0'), '.');
    $num = fn ($v) => $v === null ? null : rtrim(rtrim(number_format((float) $v, 2, '.', ''), '0'), '.');
    $show = fn ($v, $suffix = '') => $v === null ? 'Not set' : $v.$suffix;
    $loyalty = $s['loyalty'] ?? [];
@endphp

@if ($loadError)
    <div class="flash bad" role="alert"><x-icon name="alert" :size="16" />The settings could not be read: {{ $loadError }}
        (run <code>supabase/migrations/20261018000000_business_settings.sql</code> if it is missing).</div>
@else

@if ($s['carried_over'] ?? false)
    <div class="flash warn" role="status"><x-icon name="alert" :size="16" />
        These values were the app's old built-in defaults, carried over once so nothing changed by surprise.
        Please check them and press <b>Save settings</b> to confirm (or change) them.</div>
@endif

<div class="cols-2">
    <x-card title="Stock and sales rules" subtitle="Owner only. Leave a field empty for &quot;Not set&quot;.">
        <form method="POST" action="{{ route('admin.business.update') }}" data-business-settings>
            @csrf @method('PUT')
            <div class="field"><label for="restock_threshold_default">Restock threshold for items without their own (units)</label>
                <input class="light-input" id="restock_threshold_default" name="restock_threshold_default" type="number" min="0" step="1"
                       value="{{ old('restock_threshold_default', $s['restock_threshold_default'] ?? null) }}" placeholder="Not set">
                <p class="note">Not set: no "low stock" warning is raised for those items; "out of stock" still is.</p></div>
            <div class="field"><label for="stock_low_percent">Stock health: "Low" below (% of items above their threshold)</label>
                <input class="light-input" id="stock_low_percent" name="stock_low_percent" type="number" min="0" max="100" step="0.1"
                       value="{{ old('stock_low_percent', $pct($s['stock_low_ratio'] ?? null)) }}" placeholder="Not set"></div>
            <div class="field"><label for="stock_plenty_percent">Stock health: "Plenty" from (%)</label>
                <input class="light-input" id="stock_plenty_percent" name="stock_plenty_percent" type="number" min="0" max="100" step="0.1"
                       value="{{ old('stock_plenty_percent', $pct($s['stock_plenty_ratio'] ?? null)) }}" placeholder="Not set"></div>
            <div class="field"><label for="sales_low_percent">Sales rating: "Low" below (% of target)</label>
                <input class="light-input" id="sales_low_percent" name="sales_low_percent" type="number" min="0" step="0.1"
                       value="{{ old('sales_low_percent', $pct($s['sales_low_ratio'] ?? null)) }}" placeholder="Not set"></div>
            <div class="field"><label for="sales_high_percent">Sales rating: "High" above (% of target)</label>
                <input class="light-input" id="sales_high_percent" name="sales_high_percent" type="number" min="0" step="0.1"
                       value="{{ old('sales_high_percent', $pct($s['sales_high_ratio'] ?? null)) }}" placeholder="Not set"></div>
            <div class="field"><label for="default_daily_sales_target">Daily sales target for branches without their own (₱)</label>
                <input class="light-input" id="default_daily_sales_target" name="default_daily_sales_target" type="number" min="0" step="0.01"
                       value="{{ old('default_daily_sales_target', $num($s['default_daily_sales_target'] ?? null)) }}" placeholder="Not set"></div>
            <div class="field"><label for="healthy_margin_percent">Healthy product margin from (%)</label>
                <input class="light-input" id="healthy_margin_percent" name="healthy_margin_percent" type="number" min="0" max="99" step="0.1"
                       value="{{ old('healthy_margin_percent', $num($s['healthy_margin_percent'] ?? null)) }}" placeholder="Not set">
                <p class="note">Used by the app's product pricing screens. Not set: margins are shown without a rating.</p></div>
            <div class="field"><label for="expiry_alert_days">Warn branch staff about batches expiring within (days)</label>
                <input class="light-input" id="expiry_alert_days" name="expiry_alert_days" type="number" min="1" max="365" step="1"
                       value="{{ old('expiry_alert_days', $s['expiry_alert_days'] ?? null) }}" placeholder="Not set">
                <p class="note">Not set: no expiry push notifications are sent.</p></div>
            <button class="btn-solid" type="submit">Save settings</button>
        </form>
    </x-card>

    <x-card title="Loyalty and payment" subtitle="Read here, changed on their own pages">
        <div class="setting-row"><div><b>Earn rate</b><span>{{ ($loyalty['earn_pesos_per_point'] ?? null) === null ? 'Not set: customers earn no points yet' : '1 point per ₱'.$num($loyalty['earn_pesos_per_point']) }}</span></div>
            <a class="btn sm" href="{{ route('loyalty.index') }}">Loyalty</a></div>
        <div class="setting-row"><div><b>Redeem rule</b><span>{{ ($loyalty['points_per_peso'] ?? null) === null ? 'Not set: points cannot be redeemed yet' : $num($loyalty['points_per_peso']).' point(s) per ₱1 off, up to '.$num($loyalty['max_discount_percent']).'% of an order' }}</span></div></div>
        <div class="setting-row"><div><b>Online payment (GCash, Maya, card)</b><span>{{ ($s['online_payment_enabled'] ?? false) ? 'On' : 'Off (owner decision). Customers pay by Cash on Delivery or Cash on Counter Pickup.' }}</span></div>
            <x-badge :tone="($s['online_payment_enabled'] ?? false) ? 'warn' : 'info'">{{ ($s['online_payment_enabled'] ?? false) ? 'On' : 'Off' }}</x-badge></div>
        <div class="setting-row"><div><b>Message shown at checkout</b><span>{{ $s['online_payment_disabled_message'] ?? 'Not set' }}</span></div></div>
    </x-card>
</div>

<div class="block-head"><h2>Branches</h2></div>
@if (empty($s['branches']))
    <div class="card"><p class="muted" style="margin:0">No branches yet. Add the first one below: customers can order only from a branch that exists here.</p></div>
@endif
@foreach (array_merge($s['branches'] ?? [], [null]) as $b)
    <x-card :title="$b ? $b['name'] : 'Add a branch'" :subtitle="$b ? ($b['is_active'] ? 'Open to customers' : 'Temporarily closed') : 'Every field you leave empty stays Not set'">
        <form method="POST" action="{{ $b ? route('admin.branches.update', $b['id']) : route('admin.branches.store') }}" class="filter-row" data-branch-form="{{ $b['id'] ?? 'new' }}">
            @csrf @if ($b) @method('PUT') @endif
            <div class="field" style="margin:0"><label>Name</label><input class="light-input" name="name" required maxlength="80" value="{{ $b['name'] ?? '' }}"></div>
            <div class="field" style="margin:0"><label>Address</label><input class="light-input" name="address" maxlength="300" value="{{ $b['address'] ?? '' }}" placeholder="Not set"></div>
            <div class="field" style="margin:0"><label>Contact phone</label><input class="light-input" name="contact_phone" maxlength="40" value="{{ $b['contact_phone'] ?? '' }}" placeholder="09XXXXXXXXX"></div>
            <div class="field" style="margin:0"><label>Opening hours</label><input class="light-input" name="operating_hours" maxlength="200" value="{{ $b['operating_hours'] ?? '' }}" placeholder="Not set"></div>
            <div class="field" style="margin:0"><label>Delivery fee (₱, required)</label><input class="light-input" name="delivery_fee" type="number" min="0" step="0.01" required value="{{ $b ? $num($b['delivery_fee']) : '' }}"></div>
            <div class="field" style="margin:0"><label>Daily sales target (₱)</label><input class="light-input" name="daily_sales_target" type="number" min="0" step="0.01" value="{{ $b ? $num($b['daily_sales_target']) : '' }}" placeholder="Not set"></div>
            <label style="align-self:flex-end"><input type="checkbox" name="supports_delivery" value="1" @checked($b['supports_delivery'] ?? false)> Delivery</label>
            <label style="align-self:flex-end"><input type="checkbox" name="supports_pickup" value="1" @checked($b['supports_pickup'] ?? true)> Pickup</label>
            <label style="align-self:flex-end"><input type="checkbox" name="is_active" value="1" @checked($b['is_active'] ?? true)> Open</label>
            <button class="btn-solid" type="submit" style="align-self:flex-end">{{ $b ? 'Save branch' : 'Add branch' }}</button>
        </form>
    </x-card>
@endforeach
@endif
@endsection
