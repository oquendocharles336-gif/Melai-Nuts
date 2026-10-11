{{-- Same design as 403. Never shows exception details or a stack trace (APP_DEBUG=false). --}}
@extends('layouts.base')
@section('title', '404 · Page not found')
@section('content')
<main class="center-page"><div class="card" role="alert">
    <h1>Page not found</h1>
    <p>We could not find that page. It may have moved, or the link may be wrong.</p>
    <div class="btn-row"><a class="btn-solid" href="{{ url('/') }}">Go to the start page</a> <a class="btn-outline" href="{{ url()->previous() }}">Go back</a></div>
</div></main>
@endsection
