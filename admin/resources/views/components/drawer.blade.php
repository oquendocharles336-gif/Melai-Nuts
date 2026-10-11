{{-- Right-side drawer with a dimmed backdrop. `show` is an Alpine expression in the parent scope; `close` an expression that closes it. --}}
@props(['show', 'close', 'label' => 'Details'])
<template x-teleport="body">
    <div x-show="{{ $show }}" x-cloak x-on:keydown.escape.window="{{ $show }} && ({{ $close }})">
        <div class="overlay" x-on:click="{{ $close }}" x-show="{{ $show }}" x-transition:enter="t-fade-enter" x-transition:enter-start="t-fade-from" x-transition:leave="t-fade-leave" x-transition:leave-end="t-fade-from"></div>
        <aside class="drawer" role="dialog" aria-modal="true" aria-label="{{ $label }}" x-show="{{ $show }}" x-trap.noscroll="{{ $show }}"
               x-transition:enter="t-slide-enter" x-transition:enter-start="t-slide-from" x-transition:leave="t-slide-leave" x-transition:leave-end="t-slide-from">
            {{ $slot }}
        </aside>
    </div>
</template>
