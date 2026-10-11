{{-- Card reader box. $readerTitle (optional). Emits the UID to window.onCardTap(uid). --}}
<div class="card" id="rfid-reader" style="max-width:none;display:flex;flex-wrap:wrap;gap:1rem;align-items:center">
    <div style="flex:1 1 16rem">
        <strong>{{ $readerTitle ?? 'Card reader' }}</strong><br>
        <span class="status info" data-rfid-status>Not connected</span>
        <p class="muted" style="margin:.4rem 0 0;font-size:.85rem">USB reader (Arduino Uno/Nano): press Connect, choose the board. Keyboard-mode reader: click the box, then tap the card.</p>
    </div>
    <button type="button" class="btn-outline" style="padding:.45rem 1rem" data-rfid-connect>Connect USB reader</button>
    <input class="light-input" style="max-width:14rem" data-rfid-input placeholder="Tap card here…" autocomplete="off" aria-label="Tap card here">
</div>
<script src="{{ asset('js/melai-rfid.js') }}"></script>
<script>
    document.addEventListener('DOMContentLoaded', function () {
        MelaiRfid.attach(document.getElementById('rfid-reader'), function (uid) { window.onCardTap && window.onCardTap(uid); });
    });
</script>
