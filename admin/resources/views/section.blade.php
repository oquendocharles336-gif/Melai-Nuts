@extends('layouts.panel')
@section('title', $title.' · Melai Nuts Admin')
@section('page-title', $title)
@section('panel')
    {{-- On the website every sidebar page is live from the Melai Nuts database (DashboardController::section).
         This plain page is only reached by the automated tests' fake data source, so it shows no figures. --}}
    <div class="card"><h2>{{ $title }}</h2>
        <p>This page reads the Melai Nuts app's database, which is not connected here.</p>
    </div>
@endsection
