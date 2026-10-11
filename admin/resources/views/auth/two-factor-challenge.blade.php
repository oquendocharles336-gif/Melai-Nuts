@extends('layouts.auth')
@section('title', 'Two-step sign-in · Melai Nuts Admin')
@section('heading1', 'One more')
@section('heading2', 'Step')
@section('blurb', 'Two-step sign-in is on for this account. Enter the 6-digit code from your authenticator app, or one of your recovery codes.')
@section('form')
<form method="POST" action="{{ route('two-factor.verify') }}">
    @csrf
    <h2 class="form-title">Enter code</h2>
    @error('code')
        <div class="alert" role="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">{{ $message }}</div>
    @enderror
    <x-field name="code" label="Code" autocomplete="one-time-code" inputmode="numeric" placeholder="123456" />
    <button type="submit" class="btn-primary">Continue</button>
</form>
<form method="POST" action="{{ route('logout') }}" style="margin-top:12px">
    @csrf
    <button type="submit" class="link" style="background:none;border:0;cursor:pointer">Sign out instead</button>
</form>
@endsection
