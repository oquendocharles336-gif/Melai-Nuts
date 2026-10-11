@extends('layouts.panel')
@section('title', $title.' · Melai Nuts Admin')
@section('page-title', $title)
@section('panel')
    <div class="card">
        <h2>{{ $title }}</h2>
        <p>{{ $message }}</p>
        @if ($title === 'Database unavailable')
            <a class="btn-solid" style="padding:.4rem 1rem" href="{{ url()->current() }}">Try again</a>
        @endif
        <a class="btn-outline" style="padding:.4rem 1rem" href="{{ url()->previous() !== url()->current() ? url()->previous() : route('dashboard') }}">Go back</a>
    </div>
@endsection
