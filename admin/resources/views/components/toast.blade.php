{{-- Toast stack (bottom-left). Push one from JS: Alpine.store('ui').toast('Saved'). --}}
<div class="toasts" role="status" aria-live="polite">
    <template x-for="t in $store.ui.toasts" :key="t.id">
        <div class="toast" :class="t.tone" x-transition:enter="t-toast-enter" x-transition:enter-start="t-toast-from" x-transition:leave="t-toast-leave" x-transition:leave-end="t-toast-from">
            <span class="toast-dot"></span><span x-text="t.message"></span>
            <button type="button" x-on:click="$store.ui.dismiss(t.id)" aria-label="Dismiss"><x-icon name="x" :size="14" /></button>
        </div>
    </template>
</div>
