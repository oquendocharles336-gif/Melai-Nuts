{{-- Same design as 403. Never shows exception details or a stack trace (APP_DEBUG=false). --}}
@extends('layouts.base')
@section('title', '500 · Something went wrong')
@section('content')
<main class="center-page"><div class="card" role="alert">
    <h1>Something went wrong</h1>
    <p>An unexpected error happened on our side. It has been logged. Please try again in a moment.</p>
    <div class="btn-row"><a class="btn-solid" href="{{ url()->current() }}">Try again</a> <a class="btn-outline" href="{{ url('/') }}">Go to the start page</a></div>
</div></main>
@endsection
