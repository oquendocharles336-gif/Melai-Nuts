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

    <form method="POST" action="{{ route('admin.users.store') }}">
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
        <div class="field"><label>Password</label><input class="light-input" type="password" name="password"></div>
        <div class="field"><label>Confirm password</label><input class="light-input" type="password" name="password_confirmation"></div>
        <button class="btn-solid" type="submit">Create account</button>
        <a class="btn-outline" href="{{ route('admin.users.index') }}">Cancel</a>
    </form>
</div>
@endsection
