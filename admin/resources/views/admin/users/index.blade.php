@extends('layouts.panel')
@section('title', 'All users · Melai Nuts Admin')
@section('page-title', 'All users')
@section('page-sub', 'Everyone with a Melai Nuts account: website logins, app owners and staff, and customers.')
@section('page-actions')
    <a class="btn primary" href="{{ route('admin.users.create') }}"><x-icon name="plus" :size="15" /> Create account</a>
@endsection
@section('panel')
@php
    $chipUrl = fn ($t) => route('admin.users.index', array_filter(['type' => $t === 'all' ? null : $t, 'q' => $q ?: null]));
    $loginRole = ['admin' => 'Admin', 'staff' => 'Staff'];
    $me = auth()->user();
@endphp

@include('partials.flash')

@if ($directoryError)
    <div class="flash bad" role="alert"><x-icon name="alert" :size="16" />Could not load the app's accounts: {{ $directoryError }}</div>
@elseif ($partial)
    <div class="flash warn" role="status"><x-icon name="alert" :size="16" />
        The database is missing migration 20261014000000_admin_portal_all_users.sql: customers without a loyalty account are not listed and order figures are unknown. Run the migration to see everyone.</div>
@endif
@if ($appLoaded && $customersTotal > $customersShown)
    <div class="flash warn" role="status"><x-icon name="alert" :size="16" />
        Showing the newest {{ number_format($customersShown) }} of {{ number_format($customersTotal) }} customers{{ $q !== '' ? ' that match' : '' }}. Search by name, e-mail, phone or card number to find the others.</div>
@endif

<div class="people-toolbar">
    <div class="chips" role="group" aria-label="Filter users">
        @foreach (\App\Services\UserDirectory::TYPES as $t => $label)
            @continue(! $liveData && in_array($t, ['team', 'customers'], true))
            @continue($t === 'attention' && $counts['attention'] === 0 && $type !== 'attention')
            <a href="{{ $chipUrl($t) }}" class="chip {{ $type === $t ? 'is-on' : '' }}" @if ($type === $t) aria-current="true" @endif>
                {{ $label }} <span class="n">{{ number_format($counts[$t]) }}</span></a>
        @endforeach
    </div>
    <form method="GET" action="{{ route('admin.users.index') }}" role="search">
        @if ($type !== 'all')<input type="hidden" name="type" value="{{ $type }}">@endif
        <label class="input-icon"><x-icon name="search" :size="15" />
            <input class="input" type="search" name="q" value="{{ $q }}" placeholder="Name, e-mail, phone or card" aria-label="Search users"></label>
        <button class="btn" type="submit">Search</button>
        @if ($q !== '')<a class="btn ghost" href="{{ $chipUrl($type) }}">Clear</a>@endif
    </form>
</div>

<x-card flush>
    <x-table stack data-no-paginate>
        <x-slot:head><th>Person</th><th>Accounts</th><th>Branch</th><th>Status</th><th>Activity</th><th class="r"><span class="sr-only">Actions</span></th></x-slot:head>
        @forelse ($people as $p)
            @php $u = $p['login']; $s = $p['staff']; $c = $p['customer']; @endphp
            <tr>
                <td>
                    <div class="person"><span class="avatar">{{ $p['initials'] }}</span>
                        <div><b>{{ $p['name'] }}</b>
                            <span class="cell-sub">{{ $p['email'] ?: 'No e-mail' }}@if ($p['phone']) · {{ $p['phone'] }}@endif</span></div></div>
                </td>

                <td data-label="Accounts">
                    <div class="acct">
                        @if ($u)
                            <div class="acct-line"><x-badge :tone="$u->isAdmin() ? 'accent' : 'info'">Website · {{ $loginRole[$u->role] ?? ucfirst($u->role) }}</x-badge>
                                @if ($liveData)<span class="cell-sub">{{ $u->firebase_uid ? 'App sign-in'.($u->firebase_email_verified ? ', e-mail verified' : ', e-mail not verified') : 'Local password' }}</span>@endif
                            </div>
                        @endif
                        @if ($s)
                            <div class="acct-line"><x-badge :tone="$s['role'] === 'owner' ? 'accent' : 'neutral'">App · {{ ucfirst($s['role']) }}</x-badge>
                                @if ($s['role'] === 'staff' && ($s['can_review_refunds'] ?? false))<span class="cell-sub">reviews refunds</span>@endif</div>
                        @endif
                        @if ($c)
                            <div class="acct-line"><x-badge tone="neutral">App · Customer</x-badge>@if ($c['card_number'] ?? null)<span class="cell-sub">Card {{ $c['card_number'] }}</span>@endif</div>
                        @endif

                        {{-- Website login ↔ app account link (unchanged rules). --}}
                        @if ($u && $liveData && $appLoaded)
                            @if ($u->staff_uid)
                                @unless ($s)
                                    <span class="cell-sub">Linked to {{ $u->staff_uid }}</span>
                                @endunless
                                @unless ($u->is($me))
                                    <form method="POST" action="{{ route('admin.users.unlink', $u) }}" data-confirm="Unlink {{ $u->email }} from its app account? The login keeps working but loses its app access until it is linked again." data-confirm-title="Unlink this login?" data-confirm-label="Unlink">
                                        @csrf<button class="btn sm ghost" type="submit">Unlink app account</button>
                                    </form>
                                @endunless
                            @elseif (! $u->canUseWebsite())
                                <span class="cell-sub">Cannot use the website (app-only role)</span>
                            @elseif ($p['awaiting_approval'])
                                @unless ($u->firebase_email_verified)<x-badge tone="warn">E-mail not verified</x-badge>@endunless
                                <form method="POST" action="{{ route('admin.users.approve', $u) }}" x-data="{ role: 'staff' }">
                                    @csrf
                                    <select class="light-input" name="role" x-model="role" aria-label="App role">
                                        <option value="staff">Staff</option>
                                        <option value="owner">Owner</option>
                                    </select>
                                    <select class="light-input" name="branch_id" x-show="role === 'staff'" aria-label="Branch">
                                        @foreach ($branches as $b) <option value="{{ $b['id'] }}">{{ $b['name'] }}</option> @endforeach
                                    </select>
                                    @if ($needsOwnerPassword)
                                        <input class="light-input" type="password" name="owner_password" autocomplete="current-password" required
                                               placeholder="Your app password" aria-label="Your Melai Nuts app password, to confirm" title="You signed in with the website password: confirm with your Melai Nuts app password (used once, not saved).">
                                    @endif
                                    <button class="btn sm primary" type="submit" @disabled(! $u->firebase_email_verified)
                                            data-confirm="Give {{ $u->email }} OWNER rights in the Melai Nuts app (all branches, user management)?" data-confirm-title="Make this person an owner?" data-confirm-label="Approve as owner" data-confirm-if="role=owner">Approve</button>
                                </form>
                            @elseif (count($directory))
                                @php $wanted = $u->isAdmin() ? 'owner' : 'staff';
                                     $choices = collect($directory)->filter(fn ($row) => $row['role'] === $wanted && $row['is_active']
                                         && mb_strtolower($row['email']) === mb_strtolower($u->email)); @endphp
                                @if ($choices->isEmpty())
                                    <span class="cell-sub">Not linked: no active app {{ $wanted }} with this e-mail</span>
                                @else
                                    <form method="POST" action="{{ route('admin.users.link', $u) }}">
                                        @csrf
                                        <select class="light-input" name="staff_uid" aria-label="App account">
                                            @foreach ($choices as $row) <option value="{{ $row['firebase_uid'] }}">{{ $row['full_name'] }}{{ $row['branch_name'] ? ' · '.$row['branch_name'] : '' }}</option> @endforeach
                                        </select>
                                        <button class="btn sm" type="submit">Link</button>
                                    </form>
                                @endif
                            @else
                                <span class="cell-sub">Not linked to an app account</span>
                            @endif
                        @endif
                    </div>
                </td>

                <td data-label="Branch">{{ $p['branch'] ?? '—' }}</td>

                <td data-label="Status"><x-badge :tone="$p['status'][0]">{{ $p['status'][1] }}</x-badge></td>

                <td data-label="Activity">
                    @if ($c)
                        @if ($c['orders'] === null)
                            <span class="cell-sub">Orders unknown</span>
                        @else
                            <div class="num">{{ $c['orders'] }} {{ \Illuminate\Support\Str::plural('order', (int) $c['orders']) }} · {{ $peso($c['paid_total']) }} paid @if (($c['refunded_total'] ?? 0) > 0) · {{ $peso($c['refunded_total']) }} refunded @endif</div>
                        @endif
                        @if (($c['points_balance'] ?? null) !== null)<span class="cell-sub">{{ number_format($c['points_balance']) }} pts</span>@endif
                    @endif
                    @if ($u)
                        <span class="cell-sub">Last sign-in {{ $u->last_login_at?->diffForHumans() ?? 'never' }}</span>
                    @elseif ($c && ($c['last_order_at'] ?? null))
                        <span class="cell-sub">Last order {{ $p['last_seen']?->diffForHumans() }}</span>
                    @elseif (! $c)
                        <span class="cell-sub">—</span>
                    @endif
                </td>

                <td class="r">
                    <div class="row-actions">
                        @if ($u && ! $u->isAdmin())
                            <form method="POST" action="{{ route('admin.users.toggle-access', $u) }}">
                                @csrf<button class="btn sm" type="submit">{{ $u->has_access ? 'Restrict' : 'Grant access' }}</button>
                            </form>
                            <form method="POST" action="{{ route('admin.users.toggle-active', $u) }}">
                                @csrf<button class="btn sm {{ $u->is_active ? 'danger' : '' }}" type="submit">{{ $u->is_active ? 'Deactivate' : 'Reactivate' }}</button>
                            </form>
                        @endif
                        @if ($c)
                            <a class="btn sm ghost" href="{{ route('loyalty.show', $c['firebase_uid']) }}">Loyalty</a>
                        @endif
                    </div>
                </td>
            </tr>
        @empty
            <tr><td colspan="6" class="empty">
                @if ($q !== '') No one matches “{{ $q }}”{{ $type !== 'all' ? ' in '.mb_strtolower(\App\Services\UserDirectory::TYPES[$type]) : '' }}.
                @else No users here yet. @endif
            </td></tr>
        @endforelse
    </x-table>
    {{ $people->links() }}
</x-card>

@if ($liveData)
    <details class="ui-card explain">
        <summary>How website logins and app accounts fit together</summary>
        <p>Each website login acts in the Melai Nuts app's database as the staff or owner account it is linked to, and sees only what
            that account may see (owners: all branches; staff: their branch). Admins link to an <em>owner</em>, staff to a <em>staff</em>
            account, with the same e-mail. People who registered on this website have a Firebase app account but no staff registration
            yet: <strong>Approve</strong> registers them in the app (staff with a branch, or owner) once their e-mail is verified. People
            with an app account are linked automatically when they sign in.</p>
        <p>Records are shown as one person only when they share the same app account. Riders and customers are managed in the app
            (User Management); customer points and cards are on the Loyalty pages.</p>
    </details>
@endif
@endsection
