@extends('layouts.shop')

@section('title', 'Verify your email')

@section('content')
    <div class="s-auth">
        <div class="s-auth-card">
            <span class="s-empty-icon" style="width:64px;height:64px;border-radius:50%;display:grid;place-items:center;background:var(--brand-soft);color:var(--brand)"><x-icon name="check" :size="30" /></span>
            <div>
                <h1>Check your email</h1>
                <p class="s-sub">We sent a verification link to <b>{{ $email }}</b>. Open it, then come back and continue.</p>
            </div>
            <form method="POST" action="{{ route('shop.verify.check') }}">@csrf
                <button class="s-btn primary block">I've verified my email</button>
            </form>
            <form method="POST" action="{{ route('shop.verify.resend') }}">@csrf
                <button class="s-btn ghost block">Send the link again</button>
            </form>
            <p class="s-note">Can't find it? Check your spam or promotions folder. The email comes from Melai Nuts' sign-in service.</p>
            <form method="POST" action="{{ route('shop.verify.cancel') }}" class="s-auth-foot">@csrf
                <button class="s-link-btn">Cancel and go back to the shop</button>
            </form>
        </div>
    </div>
@endsection
