@extends('layouts.panel')
@section('title', 'Suppliers · Melai Nuts Admin')
@section('page-title', 'Suppliers')
@section('panel')
@include('partials.flash')
<a class="btn-outline" style="padding:.3rem .9rem;width:fit-content" href="{{ route('receipts.index') }}">&larr; Receiving</a>

<div class="block-head"><h2>Add a supplier</h2></div>
<form method="POST" action="{{ route('suppliers.store') }}" class="card" style="max-width:none;display:flex;flex-wrap:wrap;gap:.8rem;align-items:end">
    @csrf
    <div><label><strong>Name</strong></label><br><input class="light-input" name="name" required minlength="2" maxlength="120" value="{{ old('name') }}"></div>
    <div><label>Contact person</label><br><input class="light-input" name="contact_person" maxlength="120" value="{{ old('contact_person') }}"></div>
    <div><label>Phone</label><br><input class="light-input" name="phone" maxlength="40" value="{{ old('phone') }}"></div>
    <div><label>E-mail</label><br><input class="light-input" type="email" name="email" maxlength="120" value="{{ old('email') }}"></div>
    <div><label>TIN</label><br><input class="light-input" name="tin" maxlength="30" value="{{ old('tin') }}"></div>
    <div style="flex:1 1 16rem"><label>Address</label><br><input class="light-input" name="address" maxlength="250" value="{{ old('address') }}"></div>
    <button class="btn-solid" style="padding:.5rem 1.2rem" type="submit">Add</button>
</form>
<p class="muted">The supplier's name as printed on their invoices helps OCR pick the right supplier automatically.</p>

<div class="card" style="max-width:none;overflow-x:auto">
    <table class="table">
        <thead><tr><th>Name</th><th>Contact</th><th>Phone</th><th>E-mail</th><th>TIN</th><th>Approved receipts</th><th>Status</th><th></th></tr></thead>
        <tbody>
        @forelse ($suppliers as $s)
            <tr>
                <td><strong>{{ $s['name'] }}</strong><br><span class="muted">{{ $s['address'] }}</span></td>
                <td>{{ $s['contact_person'] ?? '—' }}</td><td>{{ $s['phone'] ?? '—' }}</td><td>{{ $s['email'] ?? '—' }}</td><td>{{ $s['tin'] ?? '—' }}</td>
                <td>{{ $s['receipts'] }}</td>
                <td><span class="status {{ $s['is_active'] ? 'high' : 'info' }}">{{ $s['is_active'] ? 'Active' : 'Inactive' }}</span></td>
                <td>
                    <form method="POST" action="{{ route('suppliers.update', $s['id']) }}">
                        @csrf
                        @foreach (['name', 'contact_person', 'phone', 'email', 'address', 'tin'] as $f)<input type="hidden" name="{{ $f }}" value="{{ $s[$f] }}">@endforeach
                        <input type="hidden" name="is_active" value="{{ $s['is_active'] ? 0 : 1 }}">
                        <button class="btn-outline" style="padding:.25rem .8rem" type="submit">{{ $s['is_active'] ? 'Deactivate' : 'Activate' }}</button>
                    </form>
                </td>
            </tr>
        @empty
            <tr><td colspan="8">No suppliers yet.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
@endsection
