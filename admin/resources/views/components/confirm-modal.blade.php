{{-- One confirmation dialog for every destructive or important action on the website (same look as
     every other modal). Any form (or its submit button) with data-confirm="message" opens it instead of
     the browser's native confirm():
       data-confirm-title="Delete supplier?"   heading            (default "Are you sure?")
       data-confirm-label="Delete"             confirm button     (default "Confirm")
       data-confirm-safe                       confirm button not in the danger colour
       data-confirm-if="role=owner"            ask only when that field has that value
     Cancel is focused first, so Enter / Esc never confirms by accident. See resources/js/ui.js. --}}
<x-modal name="confirm-action" :title="'Please confirm'">
    <div x-data="confirmAction()" x-on:melai-confirm.window="ask($event.detail)">
        <div class="modal-body">
            <h3 style="margin:0 0 .4rem" x-text="title"></h3>
            <p x-text="message"></p>
        </div>
        <div class="modal-foot">
            <button type="button" class="btn" x-ref="cancel" x-on:click="cancel()">Cancel</button>
            <button type="button" class="btn" :class="danger ? 'danger-solid' : 'primary'" x-on:click="go()" x-text="label"></button>
        </div>
    </div>
</x-modal>
