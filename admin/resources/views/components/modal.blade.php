{{-- Centred modal. Open with: $dispatch('open-modal', '<name>'); closes with Esc, the backdrop or $dispatch('close-modal', '<name>').
     Focus is trapped inside while open (Alpine Focus plugin) and returns to the trigger after. --}}
@props(['name', 'title', 'wide' => false])
<div x-data="modal(@js($name))" x-on:keydown.escape.window="open && close()" {{ $attributes }}>
    <template x-teleport="body">
        <div x-show="open" x-cloak>
            <div class="overlay" x-show="open" x-transition:enter="t-fade-enter" x-transition:enter-start="t-fade-from" x-transition:leave="t-fade-leave" x-transition:leave-end="t-fade-from"></div>
            <div class="modal-wrap" x-on:click.self="close()" x-show="open">
                <div class="modal {{ $wide ? 'wide' : '' }}" role="dialog" aria-modal="true" aria-labelledby="modal-{{ $name }}-title" x-show="open" x-trap.noscroll="open"
                     x-transition:enter="t-pop-enter" x-transition:enter-start="t-pop-from" x-transition:leave="t-pop-leave" x-transition:leave-end="t-pop-from">
                    <div class="modal-head"><h2 id="modal-{{ $name }}-title">{{ $title }}</h2>
                        <button class="btn ghost sm icon" type="button" x-on:click="close()" aria-label="Close"><x-icon name="x" :size="16" /></button></div>
                    {{ $slot }}
                </div>
            </div>
        </div>
    </template>
</div>
