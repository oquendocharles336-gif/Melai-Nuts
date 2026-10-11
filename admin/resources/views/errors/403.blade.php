@extends('layouts.base')
@section('title', '403 · No permission')
@section('content')
<main class="center-page"><div class="card">
    <h1>403 — No permission</h1>
    <p>Your account can't open this page. Ask an administrator if you need access.</p>
    <div class="btn-row"><a class="btn-solid" href="{{ url('/') }}">Go back</a></div>
</div></main>
@endsection
