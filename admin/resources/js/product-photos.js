// Products page > Photos (resources/views/ops/products.blade.php).
//
// The owner adds up to `max` photos per product, sees a preview before saving, replaces one in place,
// makes one the main photo (shown first in the app) or removes one. "Save" uploads the new photos one by
// one with a progress bar to App\Http\Controllers\Admin\ProductPhotoController, which stores the file in
// Supabase Storage and the URL in products.images. Every answer carries the product's photo list as the
// database now holds it, and that list is what this page shows: nothing is assumed.
//
// Large photos are resized in the browser first (longest side 1600 px, WEBP), which keeps uploads fast and
// the app light on mobile data. A small photo is uploaded as it is. When this server's PHP accepts less
// than 5 MB (upload_max_filesize / post_max_size), photos are shrunk further to fit under that limit.
//
// "Allow" step: the "Allow photo access" button in the dialog's Photo access row (or the first upload
// click) records the owner's consent ON THE SERVER (users.photo_access_allowed_at, with the time), so it
// follows the owner to any browser. It never depends on the app sign-in: that is a separate, later step
// (confirm the app password in place, only when the server could not renew the sign-in silently).
// The browser copy (localStorage) is kept only as a fallback for this visit if the server call fails.

const TYPES = ['image/jpeg', 'image/png', 'image/webp'];
const EXT = /\.(jpe?g|png|webp)$/i;
const MAX_BYTES = 5 * 1024 * 1024;   // the server and the storage bucket refuse anything larger
const MAX_EDGE = 1600;
const KEEP_AS_IS_BYTES = 1.5 * 1024 * 1024;

const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || '';
const userId = () => document.querySelector('meta[name="melai-user"]')?.content || 'guest';
const mb = (bytes) => (bytes / 1024 / 1024).toFixed(bytes < 1024 * 1024 ? 1 : 0).replace(/\.0$/, '');
let seq = 0;

// ---- "Allow" choice, per signed-in user, in this browser -----------------------------------------
const accessKey = () => `melai.photo-access.${userId()}`;
export function readPhotoAccess() {
    try {
        const v = JSON.parse(localStorage.getItem(accessKey()) || 'null');
        return v && v.allowed === true && typeof v.at === 'string' ? v : null;
    } catch (e) { return null; }   // storage blocked (private mode): ask every time
}
export function savePhotoAccess() {
    const v = { allowed: true, at: new Date().toISOString() };
    try { localStorage.setItem(accessKey(), JSON.stringify(v)); } catch (e) { /* blocked: still allowed for this visit */ }
    return v;
}
export function clearPhotoAccess() {
    try { localStorage.removeItem(accessKey()); } catch (e) { /* blocked */ }
}

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
export function checkFile(file) {
    const typeOk = TYPES.includes(file.type) || (!file.type && EXT.test(file.name));
    if (!typeOk) {
        return /\.hei[cf]$/i.test(file.name)
            ? `"${file.name}" is an HEIC photo. Save it as JPG first (on iPhone: Settings > Camera > Formats > Most Compatible).`
            : `"${file.name}" is not a JPG, PNG or WEBP photo. Choose a .jpg, .png or .webp file.`;
    }
    if (file.size > MAX_BYTES) return `"${file.name}" is ${mb(file.size)} MB. Photos can be up to 5 MB: choose a smaller photo.`;
    if (file.size === 0) return `"${file.name}" is empty.`;
    return null;
}

/**
 * Things worth a second look before saving (shown in the "Are you sure?" step). The website cannot
 * tell WHAT a photo shows, so it points out the usual signs of a wrong pick: a tiny image (icon,
 * thumbnail), or a very wide / tall one (screenshot, banner), which the square product card crops.
 */
export function photoWarnings(w, h) {
    const out = [];
    if (!w || !h) return out;
    if (Math.min(w, h) < 400) out.push(`Small photo (${w} × ${h} px): it may look blurry in the app.`);
    const ratio = Math.max(w, h) / Math.min(w, h);
    if (ratio >= 2) out.push(`Very ${w > h ? 'wide' : 'tall'} photo (${w} × ${h} px), like a screenshot or banner: the product card crops it to a square.`);
    return out;
}

/** Same file chosen twice (name, size and date match). */
export const fileKey = (f) => `${f.name}|${f.size}|${f.lastModified || 0}`;

async function prepare(file, limit = MAX_BYTES, info = {}) {
    const problem = checkFile(file);
    if (problem) throw new Error(problem);

    let image;
    try { image = await loadImage(file); } catch (e) { throw new Error(`"${file.name}" could not be opened as a photo. It may be damaged.`); }
    const w = image.width, h = image.height;
    info.w = w; info.h = h;
    if (!w || !h) throw new Error(`"${file.name}" could not be opened as a photo.`);

    if (Math.max(w, h) <= MAX_EDGE && file.size <= Math.min(KEEP_AS_IS_BYTES, limit)) return file;

    // Smaller sizes / lower quality only when the server's limit needs it.
    let blob = null;
    for (const [edge, quality] of [[MAX_EDGE, 0.86], [MAX_EDGE, 0.72], [1280, 0.72], [1024, 0.68]]) {
        const scale = Math.min(1, edge / Math.max(w, h));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(w * scale));
        canvas.height = Math.max(1, Math.round(h * scale));
        const ctx = canvas.getContext('2d');
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
        // WEBP keeps PNG transparency and is small; browsers that cannot write it give back a PNG blob.
        blob = await toBlob(canvas, 'image/webp', quality);
        if (!blob || blob.type !== 'image/webp') blob = await toBlob(canvas, file.type === 'image/png' ? 'image/png' : 'image/jpeg', quality);
        if (!blob || blob.size <= limit) break;
    }
    image.close?.();

    if (!blob) {
        if (file.size <= limit) return file;
        throw new Error(`"${file.name}" could not be resized in this browser and is larger than this website accepts (${mb(limit)} MB). Choose a smaller photo.`);
    }
    if (blob.size >= file.size && file.size <= limit) return file;   // resizing did not help: keep the original
    if (blob.size > limit) {
        throw new Error(limit < MAX_BYTES
            ? `"${file.name}" is still larger than this website accepts (${mb(limit)} MB) after resizing. Choose a smaller photo, or raise upload_max_filesize and post_max_size in php.ini to 6M.`
            : `"${file.name}" is still larger than 5 MB after resizing. Choose a smaller photo.`);
    }

    const ext = { 'image/webp': 'webp', 'image/png': 'png', 'image/jpeg': 'jpg' }[blob.type];
    return new File([blob], file.name.replace(/\.[^.]+$/, '') + '.' + ext, { type: blob.type });
}

export function productPhotosComponent(rows, { storeUrl, destroyUrl, orderUrl, sessionUrl = null, accessUrl = null, accessAt = null, max, canEdit, maxBytes = MAX_BYTES, blocker = null, reauth = false }, { api, changed }) {
    return {
        rows, max, canEdit, blocker,
        // The app sign-in for uploads is missing or ended: asked for in place (app password), never a sign-out.
        reauth: !!reauth, reauthPassword: '', reauthBusy: false, reauthError: null,
        limit: Math.min(MAX_BYTES, maxBytes || MAX_BYTES),
        currentId: null, pending: [], busy: false, error: null, confirmKey: null, dropOn: null, replacing: null,
        access: accessAt ? { allowed: true, at: accessAt } : (accessUrl ? null : readPhotoAccess()), accessBusy: false, consentOpen: false, consentFor: null, consentReturn: null,
        saveConfirmOpen: false, confirmReturn: null,

        get current() { return this.currentId ? this.rows[this.currentId] : null; },
        get isFull() { return (this.current?.images.length || 0) + this.pending.filter(p => !p.replaces).length >= this.max; },
        get photoCountLabel() { return `${this.current?.images.length || 0} of ${this.max} photos`; },
        get accessAllowed() { return !!this.access; },
        get accessLabel() {
            if (!this.access) return 'not allowed yet. Allow it to choose photos from this device; only the photos you pick are read.';
            const d = new Date(this.access.at);
            return `Allowed ✓${Number.isNaN(d.getTime()) ? '' : ' on ' + d.toLocaleDateString()}. Only the photos you choose are read.`;
        },
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
            this.consentOpen = false; this.consentFor = null; this.saveConfirmOpen = false;
            this.clearPending();
            window.dispatchEvent(new CustomEvent('close-modal', { detail: 'product-photos' }));
        },
        clearPending() {
            this.pending.forEach(p => p.src && URL.revokeObjectURL(p.src));
            this.pending = [];
        },

        /** "Upload photo" / "Replace": asks the "Allow" question first, the first time only. */
        choose(slot = null) {
            if (this.busy) return;
            if (this.blocker) { this.error = this.blocker; return; }   // only a missing server setting
            if (!this.access) { this.askAccess({ slot }); return; }
            this.pick(slot);
        },
        askAccess(what) {
            this.consentFor = what;
            this.consentReturn = document.activeElement;
            this.consentOpen = true;
            // After the focus trap starts (15 ms), like the shared confirm dialog in ui.js.
            this.$nextTick(() => setTimeout(() => this.$refs.allow?.focus(), 30));
        },
        /** Runs inside the click, so the browser still lets the file picker open. */
        allowAccess() {
            const what = this.consentFor;
            this.consentOpen = false; this.consentFor = null;
            this.recordAccess();
            if (what?.files) this.addFiles(what.files);
            else this.pick(what?.slot || null);
        },
        /** "Allow photo access" button in the Photo access row: records the consent, enables the upload box. */
        allowFromRow() {
            if (this.accessBusy) return;
            this.recordAccess(true);
        },
        /** Allowed at once for this visit (the file picker must open inside the click); saved on the server. */
        async recordAccess(announce = false) {
            this.access = savePhotoAccess();
            if (!accessUrl) return;
            this.accessBusy = true;
            try {
                const res = await api(accessUrl, { method: 'POST' });
                if (res?.allowed_at) this.access = { allowed: true, at: res.allowed_at };
                if (announce) window.Alpine?.store('ui')?.toast(res?.message || 'Photo access allowed.', 'ok', true);
            } catch (err) {
                // Still allowed for this visit; the server is asked again next time.
                if (announce) this.error = `Photo access is allowed for now, but it could not be saved (${err.message}).`;
            } finally {
                this.accessBusy = false;
            }
        },
        notNow() {
            this.consentOpen = false; this.consentFor = null;
            const back = this.consentReturn; this.consentReturn = null;
            this.$nextTick(() => back?.focus?.());
        },
        async resetAccess() {
            clearPhotoAccess();
            this.access = null;
            if (!accessUrl) return;
            try { await api(accessUrl, { method: 'DELETE' }); } catch (err) { this.error = err.message; }
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
            if (this.blocker) { this.error = this.blocker; return; }
            this.replacing = null;
            const files = [...(e.dataTransfer?.files || [])];
            if (!files.length) return;
            if (!this.access) { this.askAccess({ files }); return; }
            this.addFiles(files);
        },

        addFiles(files) {
            if (!files.length) return;
            this.error = null;
            // The same file twice is almost always a slip: keep the first, say so.
            const seen = new Set(this.pending.map(p => p.fileKey));
            const dupes = [];
            files = files.filter(f => {
                const k = fileKey(f);
                if (seen.has(k)) { dupes.push(f.name); return false; }
                seen.add(k); return true;
            });
            if (dupes.length) this.error = `${dupes.map(n => `"${n}"`).join(', ')} ${dupes.length === 1 ? 'was' : 'were'} already chosen, so ${dupes.length === 1 ? 'it was' : 'they were'} not added again.`;
            if (!files.length) return;
            if (this.replacing) {
                const old = this.pending.find(p => p.replaces === this.replacing);
                if (old) this.discard({ item: old });
                this.queue(files[0], this.replacing);
                this.replacing = null;
                return;
            }
            const room = this.max - (this.current?.images.length || 0) - this.pending.filter(p => !p.replaces).length;
            if (room <= 0) { this.error = `This product already has ${this.max} photos (the most it can have). Replace or remove one first.`; return; }
            if (files.length > room) this.error = `Only ${room} more photo${room === 1 ? '' : 's'} can be added (${this.max} at most). The first ${room === 1 ? 'one was' : room + ' were'} added.`;
            files.slice(0, room).forEach(f => this.queue(f, null));
        },

        queue(file, replaces) {
            const problem = checkFile(file);   // wrong type / over 5 MB: no preview, just the reason
            this.pending.push({ key: 'new-' + (++seq), file: null, src: problem ? '' : URL.createObjectURL(file), name: file.name,
                fileKey: fileKey(file), w: 0, h: 0, warnings: [], replaces, uploading: false, progress: 0, error: problem });
            if (problem) return;
            const item = this.pending[this.pending.length - 1];   // the reactive copy
            const info = {};
            prepare(file, this.limit, info).then(f => {
                Object.assign(item, { file: f, w: info.w, h: info.h, warnings: photoWarnings(info.w, info.h) });
            }).catch(err => { item.error = err.message; });
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
                    err.reauth = data?.reauth === true;
                    reject(err);
                };
                xhr.onerror = () => reject(new Error('Could not reach the server. Check the connection and try again.'));
                xhr.ontimeout = () => reject(new Error('The upload took too long. Check the connection and try again.'));
                xhr.send(fd);
            });
        },

        // ---- "Are you sure you want to save these photos?" -----------------------------------
        /** Save button: show every new photo with the product's name before anything is uploaded. */
        askSave() {
            if (this.busy || !this.ready.length) return;
            this.confirmReturn = document.activeElement;
            this.saveConfirmOpen = true;
            this.$nextTick(() => setTimeout(() => this.$refs.saveYes?.focus(), 30));
        },
        cancelSave() {
            this.saveConfirmOpen = false;
            const back = this.confirmReturn; this.confirmReturn = null;
            this.$nextTick(() => back?.focus?.());
        },
        confirmSave() {
            this.saveConfirmOpen = false; this.confirmReturn = null;
            this.save();
        },
        get warnedCount() { return this.ready.filter(p => p.warnings?.length).length; },
        /** Where each new photo will go, in plain words. */
        placeOf(p) {
            if (p.replaces) {
                const i = (this.current?.images || []).indexOf(p.replaces);
                return i === 0 ? 'Replaces the main photo' : `Replaces photo ${i + 1}`;
            }
            const before = (this.current?.images.length || 0) + this.ready.filter(x => !x.replaces).indexOf(p);
            return before === 0 ? 'New main photo' : `New photo ${before + 1}`;
        },

        /** Confirms the app password, then saves what is waiting (the owner stays signed in). */
        async renewSession() {
            if (this.reauthBusy || !sessionUrl) return;
            if (!this.reauthPassword) { this.reauthError = 'Enter your Melai Nuts app password.'; return; }
            this.reauthBusy = true; this.reauthError = null;
            try {
                const res = await api(sessionUrl, { method: 'POST', body: { current_password: this.reauthPassword } });
                this.reauth = false; this.reauthPassword = ''; this.error = null;
                window.Alpine?.store('ui')?.toast(res.message || 'App sign-in confirmed.', 'ok', true);
                if (this.ready.length) this.save();
            } catch (err) {
                this.reauthError = err.message;
            } finally {
                this.reauthBusy = false;
            }
        },

        /** One upload; a 409 "reauth" is retried once (the server renews the app sign-in silently when it can). */
        async uploadWithRetry(p) {
            try {
                return await this.upload(p);
            } catch (err) {
                if (!err.reauth || p.retried) throw err;
                p.retried = true; p.progress = 2;
                return await this.upload(p);
            }
        },

        async save() {
            if (this.busy || !this.ready.length) return;
            if (this.reauth) { this.error = 'Confirm your app password above first. Your photos are kept.'; return; }
            const id = this.currentId;
            this.busy = true; this.error = null; this.confirmKey = null;
            let saved = 0, failed = 0, message = '';
            // One by one, in the order they were added: the database keeps that order.
            for (const p of [...this.ready]) {
                p.uploading = true; p.progress = 2; p.error = null;
                try {
                    const res = await this.uploadWithRetry(p);
                    if (Array.isArray(res.images)) this.rows[id].images = res.images;
                    if (p.src) URL.revokeObjectURL(p.src);
                    this.pending = this.pending.filter(x => x.key !== p.key);
                    saved++; message = res.message || message;
                } catch (err) {
                    p.uploading = false; p.progress = 0; failed++;
                    if (err.reauth) {
                        // Not this photo's fault: keep it waiting, ask for the app password, stop here.
                        p.error = null; p.retried = false; this.reauth = true; this.busy = false;
                        this.error = null;   // the inline password form says what to do
                        this.$nextTick(() => this.$refs.reauthInput?.focus());
                        return;
                    }
                    p.error = err.message;
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
                if (err.reauth || err.data?.reauth) this.reauth = true;
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
