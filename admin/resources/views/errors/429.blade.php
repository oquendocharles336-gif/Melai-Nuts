{{-- Same design as 403. Never shows exception details or a stack trace (APP_DEBUG=false). --}}
@extends('layouts.base')
@section('title', '429 · Too many requests')
@section('content')
<main class="center-page"><div class="card" role="alert">
    <h1>Too many requests</h1>
    <p>You made too many changes or attempts in a short time. Please wait a minute and try again.</p>
    @if (isset($exception) && method_exists($exception, 'getHeaders') && ($exception->getHeaders()['Retry-After'] ?? null))
        <p class="muted">You can try again in {{ $exception->getHeaders()['Retry-After'] }} seconds.</p>
    @endif
    <div class="btn-row"><a class="btn-solid" href="{{ url()->previous() }}">Go back</a></div>
</div></main>
@endsection
