@extends('layouts.panel')
@section('title', 'Scan invoice · Melai Nuts Admin')
@section('page-title', 'Scan a supplier invoice')
@section('panel')
@include('partials.flash')
<a class="btn-outline" style="padding:.3rem .9rem;width:fit-content" href="{{ route('receipts.index') }}">&larr; Receiving</a>

<form method="POST" action="{{ route('receipts.store') }}" enctype="multipart/form-data" class="card" style="max-width:none" id="scan-form">
    @csrf
    <div style="display:flex;flex-wrap:wrap;gap:1rem">
        <div class="field" style="flex:1 1 14rem"><label for="branch_id">Branch that received the goods</label>
            <select class="light-input" id="branch_id" name="branch_id" required>
                @foreach ($branches as $b)<option value="{{ $b['id'] }}" @selected(old('branch_id') === $b['id'])>{{ $b['name'] }}</option>@endforeach
            </select></div>
        <div class="field" style="flex:1 1 14rem"><label for="supplier_id">Supplier</label>
            <select class="light-input" id="supplier_id" name="supplier_id">
                <option value="">Detect from the invoice</option>
                @foreach ($suppliers as $s)<option value="{{ $s['id'] }}" @selected(old('supplier_id') === $s['id'])>{{ $s['name'] }}</option>@endforeach
            </select></div>
    </div>

    <div class="field"><label for="photo">1. Photo of the invoice (flat, well lit, whole page)</label>
        <input class="light-input" type="file" id="photo" name="photo" accept="image/jpeg,image/png,image/webp" capture="environment"></div>
    <img id="preview" alt="Invoice preview" style="display:none;max-width:100%;max-height:420px;border:1px solid #e5dccf;border-radius:8px;margin-bottom:.8rem">

    <div style="display:flex;gap:.8rem;align-items:center;flex-wrap:wrap;margin-bottom:.8rem">
        <button type="button" class="btn-outline" style="padding:.45rem 1rem" id="ocr-btn" disabled>2. Read text (OCR)</button>
        <span class="status info" id="ocr-status">Choose a photo first</span>
    </div>

    <div class="field"><label for="ocr_text">3. Text read from the invoice — you can correct it, or paste text here</label>
        <textarea class="light-input" id="ocr_text" name="ocr_text" rows="12" maxlength="20000" style="font-family:ui-monospace,monospace;font-size:.85rem">{{ old('ocr_text') }}</textarea></div>
    <input type="hidden" name="ocr_confidence" id="ocr_confidence" value="{{ old('ocr_confidence') }}">

    <button class="btn-solid" type="submit">4. Create draft for review</button>
    <p class="muted" style="margin-bottom:0">Nothing is added to stock yet. On the next page you check every line, then approve.</p>
</form>

<script src="https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js"></script>
<script>
(function () {
    var input = document.getElementById('photo'), preview = document.getElementById('preview');
    var btn = document.getElementById('ocr-btn'), status = document.getElementById('ocr-status');
    var text = document.getElementById('ocr_text'), conf = document.getElementById('ocr_confidence');
    function setStatus(t, tone) { status.textContent = t; status.className = 'status ' + (tone || 'info'); }

    input.addEventListener('change', function () {
        var f = input.files && input.files[0];
        if (!f) return;
        if (f.size > 8 * 1024 * 1024) { setStatus('Photo is larger than 8 MB', 'low'); input.value = ''; return; }
        preview.src = URL.createObjectURL(f);
        preview.style.display = 'block';
        btn.disabled = false;
        setStatus('Ready — press "Read text"', 'average');
    });

    // Grayscale + contrast + enough resolution: Tesseract reads printed invoices much better.
    function prepare(img) {
        var scale = Math.min(2400 / img.naturalWidth, Math.max(1, 1600 / img.naturalWidth));
        var c = document.createElement('canvas');
        c.width = Math.round(img.naturalWidth * scale); c.height = Math.round(img.naturalHeight * scale);
        var ctx = c.getContext('2d');
        ctx.drawImage(img, 0, 0, c.width, c.height);
        var d = ctx.getImageData(0, 0, c.width, c.height), p = d.data;
        for (var i = 0; i < p.length; i += 4) {
            var g = 0.299 * p[i] + 0.587 * p[i + 1] + 0.114 * p[i + 2];
            g = Math.max(0, Math.min(255, (g - 128) * 1.4 + 128));
            p[i] = p[i + 1] = p[i + 2] = g;
        }
        ctx.putImageData(d, 0, 0);
        return c;
    }

    btn.addEventListener('click', async function () {
        if (typeof Tesseract === 'undefined') { setStatus('OCR could not load (no internet?). Type or paste the text instead.', 'low'); return; }
        btn.disabled = true;
        setStatus('Starting OCR…', 'average');
        try {
            if (!preview.complete) await new Promise(function (r) { preview.onload = r; });
            var worker = await Tesseract.createWorker('eng', 1, { logger: function (m) {
                if (m.status === 'recognizing text') setStatus('Reading… ' + Math.round(m.progress * 100) + '%', 'average');
            } });
            var res = await worker.recognize(prepare(preview));
            await worker.terminate();
            text.value = res.data.text;
            conf.value = Math.round(res.data.confidence * 100) / 100;
            var c = res.data.confidence;
            setStatus('Done — confidence ' + Math.round(c) + '%' + (c < 60 ? ' (low: retake the photo or correct the text)' : ''), c < 60 ? 'low' : 'high');
        } catch (e) {
            setStatus('OCR failed: ' + (e && e.message ? e.message : e) + '. You can type the text instead.', 'low');
        } finally { btn.disabled = false; }
    });
})();
</script>
@endsection
