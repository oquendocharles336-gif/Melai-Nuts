@extends('layouts.panel')
@section('title', 'Create Account · Melai Nuts Admin')
@section('page-title', 'Create account')
@section('panel')
<div class="card" style="max-width:32rem">
    <h2>Create a staff account</h2>
    @if ($liveData)
        <p class="muted"><strong>Staff</strong> get a Melai Nuts app account (Firebase) registered to the branch you choose, exactly as in the app's
            User Management, and can sign in to the app and this website with this email and password right away.
            Riders are created in the app's User Management and sign in to the app only.</p>
    @else
        <p class="muted">This account gets access immediately — no waiting page.</p>
    @endif

    @if ($errors->any())
        <div class="alert" style="color:#C0392B;background:#fdecea;border-color:#f5b7b1">
            <ul style="margin:0;padding-left:1.1rem">@foreach ($errors->all() as $e) <li>{{ $e }}</li> @endforeach</ul>
        </div>
    @endif

    <form method="POST" action="{{ route('admin.users.store') }}" x-data="{ show: false }">
        @csrf
        <div class="field"><label>Full name</label><input class="light-input" name="name" value="{{ old('name') }}"></div>
        <div class="field"><label>Email</label><input class="light-input" type="email" name="email" value="{{ old('email') }}"></div>
        <div class="field">
            <label>Role</label>
            <select class="light-input" name="role">
                <option value="staff" selected>Staff</option>
            </select>
        </div>
        @if ($liveData)
            <div class="field"><label>Branch (staff)</label>
                <select class="light-input" name="branch_id">
                    @forelse ($branches as $b) <option value="{{ $b['id'] }}" @selected(old('branch_id') === $b['id'])>{{ $b['name'] }}</option>
                    @empty <option value="">No branches available (sign in with your app owner account)</option> @endforelse
                </select>
            </div>
        @endif
        <div class="field"><label for="new-password">Password</label>
            <input class="light-input" id="new-password" type="password" :type="show ? 'text' : 'password'" name="password" autocomplete="new-password"></div>
        <div class="field"><label for="new-password-confirm">Confirm password</label>
            <input class="light-input" id="new-password-confirm" type="password" :type="show ? 'text' : 'password'" name="password_confirmation" autocomplete="new-password"></div>
        <label class="show-password"><input type="checkbox" x-model="show"> Show password</label>
        @if ($needsOwnerPassword ?? false)
            <div class="field"><label for="owner-password">Your Melai Nuts app password</label>
                <input class="light-input" id="owner-password" type="password" :type="show ? 'text' : 'password'" name="owner_password" autocomplete="current-password" required>
                <p class="muted" style="font-size:12.5px;margin:.35rem 0 0">You signed in with the website password. The new app account is registered as your app owner account, so confirm with the password you use in the Melai Nuts app. It is used once and not saved.</p>
            </div>
        @endif
        <button class="btn-solid" type="submit">Create account</button>
        <a class="btn-outline" href="{{ route('admin.users.index') }}">Cancel</a>
    </form>
</div>
@endsection
