@extends('layouts.card')
@section('title', 'Waiting for admin access')
@section('card')
<header class="s-dlg-head">
    @include('partials.logo')
    <h1>Waiting for admin access</h1>
</header>
@if (session('status'))<div class="s-flash ok" role="status"><x-icon name="check" :size="18" /><span>{{ session('status') }}</span></div>@endif
@if (session('error'))<div class="s-flash bad" role="alert"><x-icon name="alert" :size="18" /><span>{{ session('error') }}</span></div>@endif

<div class="s-card-copy">
    @if ($user->usesFirebase())
        <p>Your Melai Nuts app account <strong>{{ $user->email }}</strong> exists. Before you can use the dashboard:</p>
        <ol>
            <li>@if ($user->firebase_email_verified) <strong>Email verified.</strong>
                @else <strong>Verify your email:</strong> open the link Firebase sent to {{ $user->email }} (check spam), then press "Check again". @endif</li>
            <li><strong>Your owner account must be linked</strong> to the app's owner registry. Staff do not use the website: they sign in to the Melai Nuts app.</li>
        </ol>
        @if ($state && ! in_array($state['state'], ['linked', 'profile_missing'], true))
            <p class="s-note">{{ \App\Services\Auth\LinkState::describe($state['state'])[0] }}: {{ $state['message'] }}</p>
        @endif
    @else
        <p>Your account <strong>{{ $user->email }}</strong> was created. An administrator needs to give you access before you can use the dashboard.</p>
    @endif
</div>

<div class="s-card-actions">
    <a class="s-btn primary" href="{{ route('waiting') }}">Check again</a>
    @if ($user->usesFirebase() && ! $user->firebase_email_verified)
        <form method="POST" action="{{ route('waiting.verify-email') }}">@csrf<button class="s-btn ghost" type="submit">Resend verification email</button></form>
    @endif
    <form method="POST" action="{{ route('logout') }}">@csrf<button class="s-btn ghost" type="submit">Sign out</button></form>
</div>
@endsection
