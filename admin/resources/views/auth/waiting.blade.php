@extends('layouts.base')
@section('title', 'Waiting for admin access')
@section('content')
<main class="center-page"><div class="card">
    @include('partials.logo')
    <h1>Waiting for admin access</h1>
    @if (session('status')) <p class="alert">{{ session('status') }}</p> @endif
    @if (session('error')) <p class="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">{{ session('error') }}</p> @endif

    @if ($user->usesFirebase())
        <p>Your Melai Nuts app account <strong>{{ $user->email }}</strong> exists. Before you can use the console:</p>
        <ol style="text-align:left">
            <li>@if ($user->firebase_email_verified) <strong>Email verified.</strong>
                @else <strong>Verify your email:</strong> open the link Firebase sent to {{ $user->email }} (check spam), then press "Check again". @endif</li>
            <li><strong>An owner approves you</strong> on the Users page and assigns your branch. Until then your account has no staff or owner rights.</li>
        </ol>
        @if ($state && ! in_array($state['state'], ['linked', 'profile_missing'], true))
            <p class="muted">{{ \App\Services\Auth\LinkState::describe($state['state'])[0] }}: {{ $state['message'] }}</p>
        @endif
    @else
        <p>Your account <strong>{{ $user->email }}</strong> was created. An administrator needs to give you access before you can use the console.</p>
    @endif

    <div class="btn-row">
        <a class="btn-solid" href="{{ route('waiting') }}">Check again</a>
        @if ($user->usesFirebase() && ! $user->firebase_email_verified)
            <form method="POST" action="{{ route('waiting.verify-email') }}">@csrf<button class="btn-outline" type="submit">Resend verification email</button></form>
        @endif
        <form method="POST" action="{{ route('logout') }}">@csrf<button class="btn-outline" type="submit">Logout</button></form>
    </div>
</div></main>
@endsection
