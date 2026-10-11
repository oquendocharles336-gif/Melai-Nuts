{{-- Password again for money / points actions (App\Http\Middleware\ConfirmRecentPassword).
     Hidden while the password was confirmed in the last few minutes. --}}
@if (! \App\Http\Middleware\ConfirmRecentPassword::recentlyConfirmed(request()))
    <input class="light-input" type="password" name="current_password" autocomplete="current-password" required
           placeholder="Your password" aria-label="Your password, to confirm" style="min-width:9rem">
@endif
@error('current_password')<p class="note" role="alert" style="color:var(--bad);margin:.25rem 0">{{ $message }}</p>@enderror
