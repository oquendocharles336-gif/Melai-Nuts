// Products page > Photos (resources/views/ops/products.blade.php).
//
// The owner adds up to `max` photos per product, sees a preview before saving, replaces one in place,
// makes one the main photo (shown first in the app) or removes one. "Save" uploads the new photos one by
// one with a progress bar to App\Http\Controllers\Admin\ProductPhotoController, which stores the file in
// Supabase Storage and the URL in products.images. Every answer carries the product's photo list as the
// database now holds it, and that list is what this page shows: nothing is assumed.
//
// Large photos are resized in the browser first (longest side 1600 px, WEBP), which keeps uploads fast and
// the app light on mobile data. A small photo is uploaded as it is.

const TYPES = ['image/jpeg', 'image/png', 'image/webp'];
const EXT = /\.(jpe?g|png|webp)$/i;
const MAX_BYTES = 5 * 1024 * 1024;   // the server and the storage bucket refuse anything larger
const MAX_RAW_BYTES = 40 * 1024 * 1024; // bigger originals are refused before even opening them
const MAX_EDGE = 1600;
const KEEP_AS_IS_BYTES = 1.5 * 1024 * 1024;

const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || '';
let seq = 0;

function loadImage(file) {
    if (window.createImageBitmap) {
        return createImageBitmap(file, { imageOrientation: 'from-image' }).catch(() => loadWithElement(file));
    }
    return loadWithElement(file);
}

function loadWithElement(file) {
    return new Promise((resolve, reject) => {
        const url = URL.createObjectURL(file);
        const img = new Image();
        img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
        img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('unreadable')); };
        img.src = url;
    });
}

const toBlob = (canvas, type, quality) => new Promise((resolve) => canvas.toBlob(resolve, type, quality));

/** The file to upload: the original when it is already small, otherwise a resized WEBP (or JPEG / PNG). */
async function prepare(file) {
    const typeOk = TYPES.includes(file.type) || (!file.type && EXT.test(file.name));
    if (!typeOk) {
        throw new Error(/\.hei[cf]$/i.test(file.name)
            ? `"${file.name}" is an HEIC photo. Save it as JPG first (on iPhone: Settings > Camera > Formats > Most Compatible).`
            : `"${file.name}" is not a JPG, PNG or WEBP photo.`);
    }
    if (file.size > MAX_RAW_BYTES) throw new Error(`"${file.name}" is too large to open (more than 40 MB).`);

    let image;
    try { image = await loadImage(file); } catch (e) { throw new Error(`"${file.name}" could not be opened as a photo. It may be damaged.`); }
    const w = image.width, h = image.height;
    if (!w || !h) throw new Error(`"${file.name}" could not be opened as a photo.`);

    const scale = Math.min(1, MAX_EDGE / Math.max(w, h));
    if (scale === 1 && file.size <= KEEP_AS_IS_BYTES) return file;

    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(w * scale));
    canvas.height = Math.max(1, Math.round(h * scale));
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    image.close?.();

    // WEBP keeps PNG transparency and is small; browsers that cannot write it give back a PNG blob.
    let blob = await toBlob(canvas, 'image/webp', 0.86);
    if (!blob || blob.type !== 'image/webp') blob = await toBlob(canvas, file.type === 'image/png' ? 'image/png' : 'image/jpeg', 0.86);
    if (!blob) {
        if (file.size <= MAX_BYTES) return file;
        throw new Error(`"${file.name}" is larger than 5 MB and could not be resized here. Choose a smaller photo.`);
    }
    if (blob.size >= file.size && file.size <= MAX_BYTES) return file;   // resizing did not help: keep the original
    if (blob.size > MAX_BYTES) throw new Error(`"${file.name}" is still larger than 5 MB after resizing. Choose a smaller photo.`);

    const ext = { 'image/webp': 'webp', 'image/png': 'png', 'image/jpeg': 'jpg' }[blob.type];
    return new File([blob], file.name.replace(/\.[^.]+$/, '') + '.' + ext, { type: blob.type });
}

export function productPhotosComponent(rows, { storeUrl, destroyUrl, orderUrl, max, canEdit }, { api, changed }) {
    return {
        rows, max, canEdit,
        currentId: null, pending: [], busy: false, error: null, confirmKey: null, dropOn: null, replacing: null,

        get current() { return this.currentId ? this.rows[this.currentId] : null; },
        photosOf(id) { return this.rows[id]?.images || []; },
        get ready() { return this.pending.filter(p => p.file && !p.error && !p.uploading); },
        get pendingCount() { return this.ready.length; },

        /** Saved photos (a pending replacement shows in its place), then new photos, then one empty slot. */
        get slots() {
            const images = this.current?.images || [];
            const asSlot = (p, main = false) => ({ key: p.key, src: p.src, pending: true, item: p, replaces: p.replaces,
                uploading: p.uploading, progress: p.progress, error: p.error, main });
            const out = images.map((url, i) => {
                const rep = this.pending.find(p => p.replaces === url);
                return rep ? asSlot(rep, i === 0) : { key: url, src: url, url, main: i === 0, pending: false };
            });
            this.pending.filter(p => !p.replaces).forEach(p => out.push(asSlot(p)));
            if (out.length < this.max) out.push({ key: 'empty', empty: true });
            return out;
        },

        url(template) { return template.replace('__ID__', encodeURIComponent(this.currentId)); },

        openPhotos(id) {
            if (!this.canEdit || !this.rows[id]) return;
            if (this.busy && id !== this.currentId) return;
            if (id !== this.currentId) this.clearPending();
            Object.assign(this, { currentId: id, error: null, confirmKey: null });
            window.dispatchEvent(new CustomEvent('open-modal', { detail: 'product-photos' }));
        },
        closePhotos() {
            if (this.busy) return;
            this.clearPending();
            window.dispatchEvent(new CustomEvent('close-modal', { detail: 'product-photos' }));
        },
        clearPending() {
            this.pending.forEach(p => p.src && URL.revokeObjectURL(p.src));
            this.pending = [];
        },

        pick(slot = null) {
            if (this.busy) return;
            this.replacing = slot?.url || null;
            this.error = null;
            const input = document.getElementById('pp-picker');
            if (!input) return;
            input.value = '';
            input.multiple = !this.replacing;
            input.click();
        },
        picked(e) { this.addFiles([...(e.target.files || [])]); e.target.value = ''; },
        dropped(e) {
            if (this.busy) return;
            this.replacing = null;
            this.addFiles([...(e.dataTransfer?.files || [])]);
        },

        addFiles(files) {
            if (!files.length) return;
            this.error = null;
            if (this.replacing) {
                const old = this.pending.find(p => p.replaces === this.replacing);
                if (old) this.discard({ item: old });
                this.queue(files[0], this.replacing);
                this.replacing = null;
                return;
            }
            const room = this.max - (this.current?.images.length || 0) - this.pending.filter(p => !p.replaces).length;
            if (room <= 0) { this.error = `This product already has ${this.max} photos. Replace or remove one first.`; return; }
            if (files.length > room) this.error = `Only ${room} more photo${room === 1 ? '' : 's'} can be added (${this.max} at most). The first ${room === 1 ? 'one was' : room + ' were'} added.`;
            files.slice(0, room).forEach(f => this.queue(f, null));
        },

        queue(file, replaces) {
            this.pending.push({ key: 'new-' + (++seq), file: null, src: URL.createObjectURL(file), name: file.name,
                replaces, uploading: false, progress: 0, error: null });
            const item = this.pending[this.pending.length - 1];   // the reactive copy
            prepare(file).then(f => { item.file = f; }).catch(err => { item.error = err.message; });
        },

        discard(slot) {
            const p = slot.item;
            if (!p || p.uploading) return;
            if (p.src) URL.revokeObjectURL(p.src);
            this.pending = this.pending.filter(x => x !== p && x.key !== p.key);
        },

        upload(p) {
            return new Promise((resolve, reject) => {
                const fd = new FormData();
                fd.append('photo', p.file, p.file.name);
                if (p.replaces) fd.append('replace', p.replaces);
                const xhr = new XMLHttpRequest();
                xhr.open('POST', this.url(storeUrl));
                xhr.setRequestHeader('Accept', 'application/json');
                xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
                xhr.setRequestHeader('X-CSRF-TOKEN', csrf());
                xhr.timeout = 120000;
                // The bytes reaching this server are 0-90 %; storing them in Supabase is the rest.
                xhr.upload.onprogress = (e) => { if (e.lengthComputable) p.progress = Math.round(e.loaded / e.total * 90); };
                xhr.onload = () => {
                    let data = null;
                    try { data = JSON.parse(xhr.responseText); } catch (e) { /* not JSON */ }
                    if (xhr.status >= 200 && xhr.status < 300) { p.progress = 100; resolve(data || {}); return; }
                    const first = data?.errors ? Object.values(data.errors)[0]?.[0] : null;
                    const err = new Error(first || data?.message || (xhr.status === 413
                        ? 'That photo is larger than this server accepts. Choose a smaller photo.'
                        : `The upload did not work (error ${xhr.status}). Nothing was changed.`));
                    err.status = xhr.status;
                    reject(err);
                };
                xhr.onerror = () => reject(new Error('Could not reach the server. Check the connection and try again.'));
                xhr.ontimeout = () => reject(new Error('The upload took too long. Check the connection and try again.'));
                xhr.send(fd);
            });
        },

        async save() {
            if (this.busy || !this.ready.length) return;
            const id = this.currentId;
            this.busy = true; this.error = null; this.confirmKey = null;
            let saved = 0, failed = 0, message = '';
            // One by one, in the order they were added: the database keeps that order.
            for (const p of [...this.ready]) {
                p.uploading = true; p.progress = 2; p.error = null;
                try {
                    const res = await this.upload(p);
                    if (Array.isArray(res.images)) this.rows[id].images = res.images;
                    if (p.src) URL.revokeObjectURL(p.src);
                    this.pending = this.pending.filter(x => x.key !== p.key);
                    saved++; message = res.message || message;
                } catch (err) {
                    p.uploading = false; p.progress = 0; p.error = err.message; failed++;
                    if (err.status === 401 || err.status === 419) { window.location.href = '/login'; return; }
                }
            }
            this.busy = false;
            if (saved) {
                const ui = window.Alpine?.store('ui');
                ui?.toast(saved > 1 ? `${saved} photos saved. Customers see them in the app.` : (message || 'Photo saved.'), 'ok', true);
                changed('products');
            }
            if (failed) this.error = failed === 1 ? 'One photo was not saved. See the message on the photo, then try again or cancel it.' : `${failed} photos were not saved. See the messages on the photos.`;
        },

        async remove(slot) {
            if (this.busy || !slot.url) return;
            const id = this.currentId;
            this.busy = true; this.error = null;
            try {
                const res = await api(this.url(destroyUrl), { method: 'DELETE', body: { url: slot.url } });
                if (Array.isArray(res.images)) this.rows[id].images = res.images;
                window.Alpine?.store('ui')?.toast(res.message || 'Photo removed.', 'ok', true);
                changed('products');
            } catch (err) {
                this.error = err.message;
            } finally {
                this.busy = false; this.confirmKey = null;
            }
        },

        async makeMain(slot) {
            if (this.busy || !slot.url) return;
            const id = this.currentId;
            const images = [slot.url, ...this.rows[id].images.filter(u => u !== slot.url)];
            this.busy = true; this.error = null;
            try {
                const res = await api(this.url(orderUrl), { method: 'PUT', body: { images } });
                if (Array.isArray(res.images)) this.rows[id].images = res.images;
                window.Alpine?.store('ui')?.toast(res.message || 'Main photo updated.', 'ok', true);
                changed('products');
            } catch (err) {
                this.error = err.message;
            } finally {
                this.busy = false;
            }
        },
    };
}
