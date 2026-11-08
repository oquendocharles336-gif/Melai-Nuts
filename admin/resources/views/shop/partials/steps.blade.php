{{-- Cart -> Checkout -> Confirmed (same steps as the app). $current: 0, 1 or 2. --}}
<div class="s-steps" role="list" aria-label="Order steps">
    @foreach (['Cart', 'Checkout', 'Confirmed'] as $i => $label)
        @if ($i > 0)<hr aria-hidden="true" @style(['background: var(--brand)' => $i <= $current])>@endif
        <span role="listitem" @class(['on' => $i === $current, 'done' => $i < $current]) @if ($i === $current) aria-current="step" @endif>
            <i aria-hidden="true">@if ($i < $current)✓@else{{ $i + 1 }}@endif</i>{{ $label }}@if ($i < $current)<span class="sr-only"> (done)</span>@endif
        </span>
    @endforeach
</div>
