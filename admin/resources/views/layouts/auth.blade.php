@extends('layouts.base')
@section('body-class', 'auth-body')
@section('content')
<div class="auth-bg" aria-hidden="true"></div>
<div class="auth-shell">
    <section class="auth-intro">
        @include('partials.logo')
        <p class="eyebrow">MELAI NUTS</p>
        <h1 class="auth-title">@yield('heading1')<span>@yield('heading2')</span></h1>
        <p class="auth-desc">@yield('blurb')</p>
        <span class="pill">ADMINISTRATION PORTAL</span>
    </section>
    <section class="glass">@yield('form')</section>
</div>
@endsection
