{{-- Same design as 403. Never shows exception details or a stack trace (APP_DEBUG=false). --}}
@extends('layouts.base')
@section('title', '503 · Temporarily unavailable')
@section('content')
<main class="center-page"><div class="card" role="alert">
    <h1>Temporarily unavailable</h1>
    <p>The website is being updated or cannot reach the database right now. Please try again in a few minutes.</p>
    <div class="btn-row"><a class="btn-solid" href="{{ url()->current() }}">Try again</a> <a class="btn-outline" href="{{ url('/') }}">Go to the start page</a></div>
</div></main>
@endsection
