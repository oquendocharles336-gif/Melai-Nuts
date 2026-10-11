{{-- Same design as 403. Never shows exception details or a stack trace (APP_DEBUG=false). --}}
@extends('layouts.base')
@section('title', '419 · Session expired')
@section('content')
<main class="center-page"><div class="card" role="alert">
    <h1>Your session expired</h1>
    <p>For your security you were signed out after a period of inactivity. Please sign in again; nothing was changed.</p>
    <div class="btn-row"><a class="btn-solid" href="{{ route('login') }}">Sign in again</a></div>
</div></main>
@endsection
