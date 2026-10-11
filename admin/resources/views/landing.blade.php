@extends('layouts.base')
@section('title', 'Melai Nuts Admin')
@section('content')
<div class="corner-label">WELCOME ADMIN</div>

<main class="hero">
    <div class="hero-blob hero-blob-1" aria-hidden="true"></div>
    <div class="hero-blob hero-blob-2" aria-hidden="true"></div>

    <div class="hero-inner">
        <div class="hero-badge">@include('partials.logo') <span>Melai Nuts Retailing</span></div>

        <h1 class="hero-title">Run every branch<br><span>from one console.</span></h1>
        <p class="hero-sub">Sales, stock, payments, refunds and loyalty for every Melai Nuts branch — in one place, live from the app's database.</p>

        <div class="btn-row">
            <a class="btn-solid btn-lg" href="{{ route('login') }}">Login</a>
            <a class="btn-outline btn-lg" href="{{ route('register') }}">Create Account</a>
        </div>

        <ul class="hero-features">
            <li><span class="hero-feature-ico">📊</span> Live sales per branch</li>
            <li><span class="hero-feature-ico">📦</span> Stock level alerts</li>
            <li><span class="hero-feature-ico">🎁</span> Loyalty &amp; rewards</li>
        </ul>
    </div>
</main>
@endsection
