@extends('layouts.panel')
@section('title', 'Settings · Melai Nuts Admin')
@section('page-title', 'Settings')
@section('page-sub', 'Your account, how the admin looks, and what it tells you.')
@section('panel')
@php $user = auth()->user(); @endphp
<div x-data="{ tab: (location.hash || '#appearance').slice(1) }" x-init="$watch('tab', t => history.replaceState(null, '', '#' + t))">
    <div class="tabs-line" role="tablist">
        @foreach (['appearance' => 'Appearance', 'profile' => 'Profile', 'notifications' => 'Notifications', 'team' => 'Team'] as $k => $v)
            <button type="button" role="tab" :class="tab === '{{ $k }}' && 'is-on'" :aria-selected="tab === '{{ $k }}'" x-on:click="tab = '{{ $k }}'">{{ $v }}</button>
        @endforeach
    </div>

    {{-- Appearance --}}
    <div x-show="tab === 'appearance'" class="cols-2" role="tabpanel">
        <x-card title="Appearance" subtitle="Yours only; your team picks their own">
            <div class="setting-row">
                <div><b>Theme</b><span>Light, dark, or follow your device</span></div>
                <x-segmented :options="['light' => 'Light', 'system' => 'System', 'dark' => 'Dark']" :icons="['light' => 'sun', 'system' => 'monitor', 'dark' => 'moon']"
                             model="$store.ui.theme" change="$store.ui.setTheme.bind($store.ui)" light label="Theme" />
            </div>
            <div class="setting-row">
                <div><b>Accent</b><span>Charts, progress bars, highlights</span></div>
                <div class="swatches" role="radiogroup" aria-label="Accent colour">
                    <template x-for="(a, key) in $store.ui.accents" :key="key">
                        <button type="button" class="swatch" role="radio" :style="'background:' + a.color" :class="$store.ui.accent === key && 'is-on'"
                                :aria-checked="$store.ui.accent === key" :aria-label="a.label" :title="a.label" x-on:click="$store.ui.setAccent(key)"></button>
                    </template>
                </div>
            </div>
            <p class="note">Saved in this browser for {{ $user->name }}.</p>
        </x-card>
        <x-card title="Preview" subtitle="How highlights and status look with your choice (no real figures)">
            <div class="kpi-top"><span class="icon-chip accent"><x-icon name="coins" :size="16" /></span>Accent colour</div>
            <div style="margin:16px 0 10px"><x-progress-bar :value="50" :max="100" label="Accent colour preview" /></div>
            <div style="display:flex;gap:6px;flex-wrap:wrap"><x-badge tone="ok">In stock</x-badge><x-badge tone="warn">Below par</x-badge><x-badge tone="bad">Out of stock</x-badge><x-badge tone="accent">Highlight</x-badge></div>
        </x-card>
    </div>

    {{-- Profile (read-only: the account lives in the Melai Nuts app / Firebase) --}}
    <div x-show="tab === 'profile'" x-cloak role="tabpanel">
        <x-card title="Profile" subtitle="Your name, e-mail and password are managed in the Melai Nuts app">
            <div class="setting-row"><div><b>Name</b><span>{{ $user->name }}</span></div></div>
            <div class="setting-row"><div><b>E-mail</b><span>{{ $user->email }}</span></div></div>
            <div class="setting-row"><div><b>Role on this website</b><span>{{ $user->isAdmin() ? 'Admin: full access, including All users, Payments and Refunds' : 'Staff: branch operations' }}</span></div>
                <x-badge :tone="$user->isAdmin() ? 'accent' : 'info'">{{ $user->isAdmin() ? 'Admin' : 'Staff' }}</x-badge></div>
            <div class="setting-row"><div><b>Sign-in</b><span>{{ $user->usesFirebase() ? 'Melai Nuts app account (Firebase)' : 'Website password' }}</span></div>
                <x-badge :tone="filled($user->staff_uid) ? 'ok' : 'warn'">{{ filled($user->staff_uid) ? 'Linked to the app' : 'Not linked yet' }}</x-badge></div>
            @if ($user->last_login_at)<div class="setting-row"><div><b>Last sign-in</b><span>{{ $user->last_login_at->setTimezone(config('app.timezone'))->format('M j, Y g:i A') }}</span></div></div>@endif
            @unless ($user->isAdmin())
            <div class="setting-row"><div><b>Two-step sign-in</b><span>{{ $user->hasTwoFactor() ? 'On: a code from your authenticator app is asked after the password' : 'Off (optional)' }}</span></div>
                <x-badge :tone="$user->hasTwoFactor() ? 'ok' : 'info'">{{ $user->hasTwoFactor() ? 'On' : 'Off' }}</x-badge></div>
            @endunless
            <div style="margin-top:14px"><a class="btn sm" href="{{ route('password.request') }}">Reset password</a>
                @unless ($user->isAdmin())
                <a class="btn sm" href="{{ route('two-factor.show') }}">{{ $user->hasTwoFactor() ? 'Manage two-step sign-in' : 'Set up two-step sign-in' }}</a>
                @endunless</div>
        </x-card>
    </div>

    {{-- Notifications (this browser) --}}
    <div x-show="tab === 'notifications'" x-cloak role="tabpanel">
        <x-card title="Notifications" subtitle="Saved in this browser">
            <div class="setting-row"><div><b>Toasts after actions</b><span>A short note bottom-left when something is saved. Errors always show.</span></div>
                <button type="button" class="switch-ui" role="switch" :aria-checked="$store.ui.toastsOn.toString()" x-on:click="$store.ui.setToasts(!$store.ui.toastsOn)" aria-label="Toasts after actions"></button></div>
            <div class="setting-row"><div><b>Live refresh</b><span>Re-read the Overview numbers every minute while the tab is open</span></div>
                <button type="button" class="switch-ui" role="switch" :aria-checked="$store.ui.liveRefresh.toString()" x-on:click="$store.ui.setLive(!$store.ui.liveRefresh)" aria-label="Live refresh"></button></div>
            <div class="setting-row"><div><b>Sidebar badges</b><span>Active orders, items running low{{ $user->isAdmin() ? ' and pending refunds' : '' }}; always on</span></div>
                <button type="button" class="switch-ui" role="switch" aria-checked="true" disabled aria-label="Sidebar badges (always on)" style="opacity:.5"></button></div>
        </x-card>
    </div>

    {{-- Team --}}
    <div x-show="tab === 'team'" x-cloak role="tabpanel">
        <x-card title="Team" subtitle="Who can use this website">
            @if ($user->isAdmin())
                <div class="setting-row"><div><b>Website accounts</b><span>{{ \App\Models\User::count() }} accounts · {{ \App\Models\User::where('has_access', true)->count() }} with access</span></div>
                    <a class="btn sm primary" href="{{ route('admin.users.index') }}">All users</a></div>
                <div class="setting-row"><div><b>Activity</b><span>Sign-ins, approvals and admin actions</span></div>
                    <a class="btn sm" href="{{ route('admin.logs') }}">Activity logs</a></div>
            @else
                <p class="muted" style="margin:0">Only an admin can add people or change roles. Ask the owner if you need more access.</p>
            @endif
        </x-card>
    </div>
</div>
@endsection
