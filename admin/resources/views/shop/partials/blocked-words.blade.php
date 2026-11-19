{{-- The blocked-words list for the live "Please keep your message respectful" check (shop.js,
     resources/js/blocked-words.js). Data only, never run. The server checks the same list again. --}}
<script type="application/json" id="melai-blocked-words">@json(\App\Support\BlockedWords::clientData())</script>
