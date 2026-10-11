@extends('layouts.panel')
@section('title', 'Help · Melai Nuts Admin')
@section('page-title', 'Help')
@section('page-sub', 'Shortcuts and where the numbers come from.')
@section('panel')
<div class="cols-2">
    <x-card title="Keyboard shortcuts">
        <div class="kbd-list">
            <div><span>Search pages, orders and products</span><span><kbd class="kbd">⌘</kbd> / <kbd class="kbd">Ctrl</kbd> + <kbd class="kbd">K</kbd></span></div>
            <div><span>Go to Orders</span><span><kbd class="kbd">G</kbd> then <kbd class="kbd">O</kbd></span></div>
            <div><span>Go to Stock</span><span><kbd class="kbd">G</kbd> then <kbd class="kbd">S</kbd></span></div>
            <div><span>Go to Reports</span><span><kbd class="kbd">G</kbd> then <kbd class="kbd">R</kbd></span></div>
            <div><span>Go to Overview</span><span><kbd class="kbd">G</kbd> then <kbd class="kbd">H</kbd></span></div>
            <div><span>New order</span><span><kbd class="kbd">N</kbd></span></div>
            <div><span>Search the table on this page</span><span><kbd class="kbd">/</kbd></span></div>
            <div><span>Close a dialog or drawer</span><span><kbd class="kbd">Esc</kbd></span></div>
        </div>
    </x-card>
    <x-card title="Where the numbers come from">
        <div class="setting-row"><div><b>One source of truth</b><span>Everything is read live from the Melai Nuts app's database. Nothing is typed in or estimated here.</span></div></div>
        <div class="setting-row"><div><b>Revenue</b><span>Payments confirmed in the period, minus completed refunds. Pending, failed and cancelled orders are not revenue.</span></div></div>
        <div class="setting-row"><div><b>Running low</b><span>A product at or under its restock level in a branch. The app has no par level, so the restock level is used.</span></div></div>
        <div class="setting-row"><div><b>Actions</b><span>Moving an order, receiving stock and recording a sale use the app's own functions, with the same permission checks as the app.</span></div></div>
    </x-card>
</div>
@endsection
