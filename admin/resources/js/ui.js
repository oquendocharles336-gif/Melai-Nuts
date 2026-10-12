// Melai Nuts admin UI: Alpine stores (theme, accent, toasts, sidebar counts), keyboard shortcuts,
// the command palette, count-up numbers and the page components (Overview, Orders, Stock, New order).
// The server stays the source of truth: every mutation goes to a Laravel route that calls the app's
// own Supabase function; the screen updates optimistically and rolls back if the server refuses.

import { lineChart, barChart, sparkPath } from './charts';
import { peso, int, pct, shortDate, longDate, dateTime, ago, initials } from './format';

const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || '';
const uid = () => document.querySelector('meta[name="melai-user"]')?.content || 'guest';
const store = (k, v) => { try { v === undefined ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) { /* private mode */ } };
const read = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
const reduced = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

export const ACCENTS = {
    yellow: { label: 'Yellow', color: '#F2C14E' },
    mint: { label: 'Mint', color: '#5CC9A7' },
    pink: { label: 'Pink', color: '#F28DB2' },
    blue: { label: 'Blue', color: '#6FA8F5' },
};

/** Like api(), plus whether the server answered from a stale cache (X-Melai-Stale). */
export async function apiMeta(url) {
    const r = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' } });
    if (r.status === 401 || r.status === 419) { window.location.href = '/login'; }
    let data = null;
    try { data = await r.json(); } catch (e) { /* empty body */ }
    if (!r.ok) { const err = new Error(data?.message || `Request failed (${r.status})`); err.status = r.status; throw err; }
    return { data, stale: r.headers.get('X-Melai-Stale') === '1' };
}

// ---- sessionStorage: small per-user cache of JSON answers (≈30 s) ---------------------------
const SS_TTL = 30000;
const ssKey = (name) => `melai.${uid()}.${name}`;
export function ssGet(name) {
    try { const v = JSON.parse(sessionStorage.getItem(ssKey(name)) || 'null'); return v && typeof v.at === 'number' ? v : null; } catch (e) { return null; }
}
export function ssSet(name, data) { try { sessionStorage.setItem(ssKey(name), JSON.stringify({ at: Date.now(), data })); } catch (e) { /* full or blocked */ } }
export function ssClear() {
    try { Object.keys(sessionStorage).filter(k => k.startsWith(`melai.${uid()}.`)).forEach(k => sessionStorage.removeItem(k)); } catch (e) { /* blocked */ }
}

export async function api(url, { method = 'GET', body } = {}) {
    const r = await fetch(url, {
        method, credentials: 'same-origin',
        headers: { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest', 'X-CSRF-TOKEN': csrf(), ...(body ? { 'Content-Type': 'application/json' } : {}) },
        body: body ? JSON.stringify(body) : undefined,
    });
    let data = null;
    try { data = await r.json(); } catch (e) { /* empty body */ }
    if (r.status === 401 || r.status === 419) { window.location.href = '/login'; }
    if (!r.ok) {
        const first = data?.errors ? Object.values(data.errors)[0]?.[0] : null;
        const err = new Error(first || data?.message || `Request failed (${r.status})`);
        err.status = r.status; err.data = data;
        throw err;
    }
    return data;
}

/** Tells every listening component (Overview, badges, tables) that data changed on the server. */
export const changed = (what) => { ssClear(); fragments.clear(); window.dispatchEvent(new CustomEvent('melai:changed', { detail: what })); };

function animateNumber(el, to, fmt) {
    const from = Number(el.dataset.countFrom ?? 0);
    el.dataset.countFrom = to ?? 0;
    if (to === null || to === undefined || Number.isNaN(Number(to))) { el.textContent = fmt(null); return; }
    if (reduced() || from === Number(to)) { el.textContent = fmt(Number(to)); return; }
    const start = performance.now(), dur = 700;
    cancelAnimationFrame(el._raf);
    const tick = (now) => {
        const k = Math.min(1, (now - start) / dur), e = 1 - Math.pow(1 - k, 3);
        el.textContent = fmt(from + (Number(to) - from) * e);
        if (k < 1) el._raf = requestAnimationFrame(tick); else el.textContent = fmt(Number(to));
    };
    el._raf = requestAnimationFrame(tick);
}

export function registerUi(Alpine) {
    // ---- magics ---------------------------------------------------------------------------
    Alpine.magic('peso', () => peso);
    Alpine.magic('int', () => int);
    Alpine.magic('pct', () => pct);
    Alpine.magic('date', () => shortDate);
    Alpine.magic('longdate', () => longDate);
    Alpine.magic('datetime', () => dateTime);
    Alpine.magic('ago', () => ago);
    Alpine.magic('initials', () => initials);
    Alpine.magic('spark', () => sparkPath);

    // x-count="value" (modifiers: .peso .compact .int .pct) — counts up from the previous value.
    Alpine.directive('count', (el, { expression, modifiers }, { effect, evaluateLater }) => {
        const get = evaluateLater(expression);
        const fmt = modifiers.includes('peso') ? (v) => peso(v, modifiers.includes('compact'))
            : modifiers.includes('pct') ? (v) => pct(v) : (v) => int(v === null ? null : Math.round(v));
        effect(() => get((v) => animateNumber(el, v, fmt)));
    });


    // x-trap="open" (modifiers: .noscroll): while true, Tab stays inside the element, the first
    // field gets focus, and focus goes back to the trigger when it closes. (No extra package needed.)
    Alpine.directive('trap', (el, { expression, modifiers }, { effect, evaluateLater, cleanup }) => {
        const get = evaluateLater(expression);
        let active = false, previous = null;
        const focusables = () => [...el.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')]
            .filter(n => n.getClientRects().length > 0);
        const onKey = (e) => {
            if (e.key !== 'Tab') return;
            const list = focusables();
            if (!list.length) { e.preventDefault(); return; }
            const first = list[0], last = list[list.length - 1];
            if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
            else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
            else if (!el.contains(document.activeElement)) { e.preventDefault(); first.focus(); }
        };
        const on = () => {
            if (active) return; active = true;
            previous = document.activeElement;
            document.addEventListener('keydown', onKey, true);
            if (modifiers.includes('noscroll')) document.documentElement.style.overflow = 'hidden';
            setTimeout(() => { const list = focusables(); const field = list.find(n => /INPUT|SELECT|TEXTAREA/.test(n.tagName)); (field || list[0])?.focus(); }, 60);
        };
        const off = () => {
            if (!active) return; active = false;
            document.removeEventListener('keydown', onKey, true);
            if (modifiers.includes('noscroll')) document.documentElement.style.overflow = '';
            if (previous && document.contains(previous)) previous.focus?.();
        };
        effect(() => get((v) => (v ? on() : off())));
        cleanup(off);
    });

    // ---- stores ---------------------------------------------------------------------------
    Alpine.store('ui', {
        theme: read(`melai.theme.${uid()}`) || 'light',
        accent: read(`melai.accent.${uid()}`) || 'yellow',
        toastsOn: read(`melai.toasts.${uid()}`) !== 'off',
        liveRefresh: read(`melai.live.${uid()}`) !== 'off',
        accents: ACCENTS,
        toasts: [],
        nav: false,
        palette: false,
        setTheme(t) { this.theme = t; store(`melai.theme.${uid()}`, t); document.documentElement.dataset.theme = t; },
        setAccent(a) { if (!ACCENTS[a]) return; this.accent = a; store(`melai.accent.${uid()}`, a); document.documentElement.dataset.accent = a; },
        setToasts(on) { this.toastsOn = on; store(`melai.toasts.${uid()}`, on ? 'on' : 'off'); },
        setLive(on) { this.liveRefresh = on; store(`melai.live.${uid()}`, on ? 'on' : 'off'); },
        toast(message, tone = 'ok', force = false) {
            if (!this.toastsOn && !force && tone !== 'bad') return;
            const id = Math.random().toString(36).slice(2);
            this.toasts.push({ id, message, tone });
            setTimeout(() => this.dismiss(id), tone === 'bad' ? 6500 : 4200);
        },
        dismiss(id) { this.toasts = this.toasts.filter(t => t.id !== id); },
    });

    Alpine.store('counts', {
        orders: null, low: null, refunds: null, month: null, loaded: false,
        // Shown from sessionStorage at once; the network is only asked when that copy is older than
        // ~30 s (or after a change), and a stale server answer is re-asked with ?fresh=1 in the background.
        async refresh(fresh = false) {
            const kept = fresh ? null : ssGet('counts');
            if (kept) {
                Object.assign(this, kept.data, { loaded: true });
                if (Date.now() - kept.at < SS_TTL) return;
            }
            try {
                const { data, stale } = await apiMeta('/ui/counts.json' + (fresh ? '?fresh=1' : ''));
                Object.assign(this, data, { loaded: true });
                ssSet('counts', data);
                if (stale && !fresh) this.refresh(true);
            } catch (e) { /* badges keep their last real value */ }
        },
    });

    // ---- components -----------------------------------------------------------------------
    Alpine.data('lineChart', lineChart);
    Alpine.data('barChart', barChart);

    // Modal: <div x-data="modal('name')"> … opens on window event open-modal with detail 'name'.
    Alpine.data('modal', (name) => ({
        open: false,
        init() {
            window.addEventListener('open-modal', (e) => { if (e.detail === name || e.detail?.name === name) this.show(e.detail?.payload); });
            window.addEventListener('close-modal', (e) => { if (!e.detail || e.detail === name) this.open = false; });
        },
        show() { this.open = true; },
        close() { this.open = false; },
    }));

    // Confirmation for forms marked data-confirm (replaces the browser's confirm()).
    Alpine.data('confirmAction', () => ({
        title: '', message: '', label: 'Confirm', danger: true, pending: null,
        ask(d) {
            Object.assign(this, { title: d.title, message: d.message, label: d.label, danger: d.danger, pending: d });
            window.dispatchEvent(new CustomEvent('open-modal', { detail: 'confirm-action' }));
            this.$nextTick(() => setTimeout(() => this.$refs.cancel?.focus(), 30));
        },
        cancel() { this.pending = null; window.dispatchEvent(new CustomEvent('close-modal', { detail: 'confirm-action' })); },
        go() {
            const p = this.pending; this.pending = null;
            window.dispatchEvent(new CustomEvent('close-modal', { detail: 'confirm-action' }));
            if (!p) return;
            p.form.dataset.confirmed = '1';
            if (p.form.hasAttribute('data-disable-on-submit')) p.form.querySelectorAll('button').forEach(b => { b.disabled = true; });
            p.form.requestSubmit(p.submitter || undefined);
        },
    }));

    Alpine.data('palette', () => paletteComponent());
    Alpine.data('liveRefresh', (seconds) => liveRefreshComponent(seconds));
    Alpine.data('overview', (opts) => overviewComponent(opts));
    Alpine.data('ordersPage', (rows, opts) => ordersComponent(rows, opts));
    Alpine.data('stockPage', (items, opts) => stockComponent(items, opts));
    Alpine.data('newOrder', (opts) => newOrderComponent(opts));
}

/** Theme + accent, keyboard shortcuts, flash → toast, badge refresh. Runs once per page. */
export function bootUi(Alpine) {
    const ui = Alpine.store('ui');
    document.documentElement.dataset.theme = ui.theme;
    document.documentElement.dataset.accent = ui.accent;

    if (document.querySelector('[data-app-shell]')) {
        Alpine.store('counts').refresh();
        window.addEventListener('melai:changed', () => Alpine.store('counts').refresh(true));
        setInterval(() => { if (!document.hidden) Alpine.store('counts').refresh(); }, 60000);
    }
    (window.MelaiFlash || []).forEach(f => ui.toast(f.message, f.tone, true));

    // data-confirm on a form or its submit button: ask in the shared confirm modal first.
    document.addEventListener('submit', (e) => {
        const form = e.target;
        if (!(form instanceof HTMLFormElement)) return;
        if (form.dataset.confirmed === '1') { delete form.dataset.confirmed; return; }
        const src = e.submitter?.dataset?.confirm ? e.submitter : (form.dataset.confirm ? form : null);
        if (!src) return;
        const cond = src.dataset.confirmIf;
        if (cond) {
            const [field, value] = cond.split('=');
            if (form.elements[field]?.value !== value) return;
        }
        e.preventDefault();
        window.dispatchEvent(new CustomEvent('melai-confirm', { detail: {
            form, submitter: e.submitter,
            title: src.dataset.confirmTitle || 'Are you sure?',
            message: src.dataset.confirm,
            label: src.dataset.confirmLabel || 'Confirm',
            danger: !src.hasAttribute('data-confirm-safe'),
        } }));
    }, true);

    // This browser runs our JavaScript: heavy pages may now answer with an instant shell (ShellFirst).
    document.cookie = 'melai_js=1; path=/; max-age=31536000; SameSite=Lax';
    if (document.querySelector('[data-app-shell]')) {
        bootSoftNavigation();
        if (document.querySelector('[data-shell]')) navigate(location.href, { push: false, fromShell: true });
    }

    let pendingG = 0;
    const nav = (key) => { const item = (window.MelaiNav || []).find(n => n.key === key); if (item) navigate(item.url); };
    window.addEventListener('keydown', (e) => {
        const typing = e.target.closest?.('input, textarea, select, [contenteditable="true"]');
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); ui.palette = !ui.palette; return; }
        const overlayOpen = [...document.querySelectorAll('.overlay')].some(o => o.getClientRects().length > 0);
        if (typing || e.metaKey || e.ctrlKey || e.altKey || ui.palette || overlayOpen) return;
        const k = e.key.toLowerCase();
        if (pendingG && Date.now() - pendingG < 1200) {
            pendingG = 0;
            const map = { o: 'orders', s: 'stock', r: 'reports', h: 'overview', p: 'products' };
            if (map[k]) { e.preventDefault(); nav(map[k]); }
            return;
        }
        if (k === 'g') { pendingG = Date.now(); return; }
        if (k === 'n' && document.querySelector('[data-new-order]')) { e.preventDefault(); window.dispatchEvent(new CustomEvent('open-modal', { detail: 'new-order' })); }
        if (k === '/' ) { const s = document.querySelector('[data-page-search]'); if (s) { e.preventDefault(); s.focus(); } }
    });
}

// ---------------------------------------------------------------------------------------------
// Command palette (⌘K): pages, then orders and products from /ui/search.json
// ---------------------------------------------------------------------------------------------
function paletteComponent() {
    return {
        q: '', active: 0, remote: [], busy: false, timer: null,
        get pages() {
            const q = this.q.trim().toLowerCase();
            return (window.MelaiNav || []).filter(n => !q || n.label.toLowerCase().includes(q) || (n.group || '').toLowerCase().includes(q))
                .map(n => ({ type: 'Pages', label: n.label, hint: n.group, url: n.url, icon: n.icon }));
        },
        get actions() {
            const q = this.q.trim().toLowerCase(), list = [];
            if (document.querySelector('[data-new-order]') && (!q || 'new order sale'.includes(q))) list.push({ type: 'Actions', label: 'New order', hint: 'N', run: () => window.dispatchEvent(new CustomEvent('open-modal', { detail: 'new-order' })) });
            if (!q || 'toggle theme dark light'.includes(q)) list.push({ type: 'Actions', label: 'Switch light / dark', hint: 'Theme', run: () => { const ui = Alpine.store('ui'); ui.setTheme(ui.theme === 'dark' ? 'light' : 'dark'); } });
            return list;
        },
        get results() { return [...this.actions, ...this.pages, ...this.remote]; },
        get groups() {
            const g = {};
            this.results.forEach((r, i) => { (g[r.type] ||= []).push({ ...r, i }); });
            return Object.entries(g);
        },
        init() {
            this.$watch('$store.ui.palette', (open) => { if (open) { this.q = ''; this.remote = []; this.active = 0; this.$nextTick(() => this.$refs.input?.focus()); } });
            this.$watch('q', () => {
                this.active = 0;
                clearTimeout(this.timer);
                const q = this.q.trim();
                if (q.length < 2) { this.remote = []; return; }
                this.timer = setTimeout(async () => {
                    this.busy = true;
                    try { this.remote = (await api('/ui/search.json?q=' + encodeURIComponent(q))).map(r => ({ ...r, type: r.type })); }
                    catch (e) { this.remote = []; }
                    finally { this.busy = false; }
                }, 180);
            });
        },
        key(e) {
            const n = this.results.length;
            if (e.key === 'ArrowDown') { e.preventDefault(); this.active = (this.active + 1) % Math.max(1, n); this.scroll(); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); this.active = (this.active - 1 + n) % Math.max(1, n); this.scroll(); }
            else if (e.key === 'Enter') { e.preventDefault(); this.go(this.results[this.active]); }
        },
        scroll() { this.$nextTick(() => this.$root.querySelector('.palette-item.is-on')?.scrollIntoView({ block: 'nearest' })); },
        go(r) {
            if (!r) return;
            Alpine.store('ui').palette = false;
            if (r.run) r.run(); else if (r.url) navigate(r.url);
        },
    };
}

// ---------------------------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------------------------
function overviewComponent({ url, range = 30, branch = null }) {
    return {
        range, branch, data: null, loading: true, error: null, filter: 'all',
        get rev() { return this.data?.revenue || { total: null, delta: null, series: [] }; },
        get k() { return this.data?.kpis || {}; },
        get pipe() { return this.data?.pipeline || { counts: { new: 0, packing: 0, shipped: 0, delivered: 0 }, total: 0, returned: 0 }; },
        get activity() { return (this.data?.activity || []).filter(a => this.filter === 'all' || a.area === this.filter); },
        get channelMax() { return Math.max(1, ...(this.data?.channels || []).map(c => Math.abs(c.amount))); },
        init() {
            this.load();
            this.onChange = () => this.load(true);
            window.addEventListener('melai:changed', this.onChange);
            this.timer = setInterval(() => { if (!document.hidden && Alpine.store('ui').liveRefresh && this.$el.isConnected) this.load(true, true); }, 60000);
        },
        destroy() { clearInterval(this.timer); window.removeEventListener('melai:changed', this.onChange); },
        async setRange(r) { if (r === this.range) return; this.range = r; await this.load(); },
        async load(fresh = false, quiet = false) {
            const name = `overview.${this.range}.${this.branch || ''}`;
            const kept = fresh ? null : ssGet(name);
            if (kept) {
                this.data = kept.data; this.loading = false;
                if (Date.now() - kept.at < SS_TTL) return; // fresh enough: no request at all
                quiet = true;                                // shown at once, updated in the background
            }
            if (!quiet) this.loading = true;
            try {
                const q = new URLSearchParams({ range: this.range, ...(this.branch ? { branch: this.branch } : {}), ...(fresh ? { fresh: 1 } : {}) });
                const { data, stale } = await apiMeta(`${url}?${q}`);
                this.data = data;
                ssSet(name, data);
                this.error = null;
                if (stale && !fresh) setTimeout(() => this.load(true, true), 0);
            } catch (e) {
                this.error = e.message;
                if (!quiet) Alpine.store('ui').toast('Could not load the overview: ' + e.message, 'bad');
            } finally { this.loading = false; }
        },
        deltaClass(d) { return d === null || d === undefined ? 'flat' : d > 0 ? 'up' : d < 0 ? 'down' : 'flat'; },
        deltaText(d) { return d === null || d === undefined ? 'No earlier data' : (d > 0 ? '↑ ' : d < 0 ? '↓ ' : '') + Math.abs(d).toFixed(1) + '%'; },
        pipeFlex(key) { return this.pipe.total ? this.pipe.counts[key] : 1; },
        exportCsv() {
            if (!this.data) return;
            const rows = [['date', 'net_revenue']].concat(this.rev.series.map(p => [p.date, p.value]));
            rows.push([], ['metric', 'value', 'change_vs_previous_%'],
                ['revenue', this.rev.total, this.rev.delta ?? ''], ['orders', this.k.orders?.value, this.k.orders?.delta ?? ''],
                ['items_sold', this.k.items?.value, this.k.items?.delta ?? ''], ['average_order', this.k.average?.value ?? '', this.k.average?.delta ?? ''],
                ['running_low', this.k.low?.value, '']);
            download(`melai-overview-${this.data.from}-to-${this.data.to}.csv`, rows);
            Alpine.store('ui').toast('Exported the last ' + this.range + ' days');
        },
    };
}

function download(name, rows) {
    const csv = rows.map(r => r.map(v => { const s = v === null || v === undefined ? '' : String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }).join(',')).join('\n');
    const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(new Blob([csv], { type: 'text/csv' })), download: name });
    document.body.appendChild(a); a.click(); a.remove();
}

// ---------------------------------------------------------------------------------------------
// Orders: filter chips + search, right-side drawer, "Move to next stage"
// ---------------------------------------------------------------------------------------------
const STAGES = ['new', 'packing', 'shipped', 'delivered'];
function ordersComponent(rows, { advanceUrl, live, open }) {
    return {
        rows, live, status: 'all', q: '', branch: '', selectedId: null, busy: false, limit: 60,
        get selected() { return this.rows.find(r => r.id === this.selectedId) || null; },
        get filtered() {
            const q = this.q.trim().toLowerCase();
            return this.rows.filter(r => (this.status === 'all' || (this.status === 'other' ? !r.stage : r.stage === this.status))
                && (!this.branch || r.branch === this.branch)
                && (!q || r.id.toLowerCase().includes(q) || (r.customer || '').toLowerCase().includes(q) || r.items.join(' ').toLowerCase().includes(q)));
        },
        get visible() { return this.filtered.slice(0, this.limit); },
        count(s) { return this.rows.filter(r => (s === 'all' || (s === 'other' ? !r.stage : r.stage === s)) && (!this.branch || r.branch === this.branch)).length; },
        init() {
            if (open) this.$nextTick(() => this.show(open));
            this.$watch('status', () => this.limit = 60); this.$watch('q', () => this.limit = 60);
        },
        show(id) { if (this.rows.some(r => r.id === id)) this.selectedId = id; },
        close() { this.selectedId = null; },
        stageIndex(r) { return r && r.stage ? STAGES.indexOf(r.stage) : -1; },
        stepState(r, i) { const s = this.stageIndex(r); return s < 0 ? '' : i < s || (i === s && r.status === 'completed') ? 'done' : i === s ? 'current' : ''; },
        async advance() {
            const r = this.selected;
            if (!r || !r.next || this.busy) return;
            if (!this.live) { Alpine.store('ui').toast('Moving orders needs the Melai Nuts app database.', 'bad'); return; }
            const before = { ...r };
            this.busy = true;
            // Optimistic: show the next step right away, then take the server's answer.
            const nextStage = { confirmed: 'new', preparing: 'packing', readyForPickup: 'shipped', completed: 'delivered' }[r.next];
            Object.assign(r, { status: r.next, statusLabel: r.nextLabel, stage: nextStage, tone: r.next === 'completed' ? 'ok' : 'warn', next: null });
            try {
                const res = await api(advanceUrl.replace('__ID__', encodeURIComponent(before.id)), { method: 'POST', body: { from: before.status } });
                Object.assign(r, res.order);
                Alpine.store('ui').toast(res.message);
                changed('orders');
            } catch (e) {
                Object.assign(r, e.data?.order || before);
                Alpine.store('ui').toast(e.message, 'bad');
            } finally { this.busy = false; }
        },
    };
}

// ---------------------------------------------------------------------------------------------
// Stock: tabs, category filter, level bars, "Receive stock" modal, count sheet
// ---------------------------------------------------------------------------------------------
function stockComponent(items, { receiveUrl, branch, branchName, live }) {
    return {
        items, tab: 'all', category: '', q: new URLSearchParams(location.search).get('q') || '', busy: false, live,
        form: { variant_id: '', quantity: '', batch_code: '', expiration_date: '' }, formError: null, flash: null,
        get categories() { return [...new Set(this.items.map(i => i.category).filter(Boolean))].sort(); },
        get maxLevel() { return Math.max(1, ...this.items.map(i => Math.max(i.qty, i.threshold * 2))); },
        get summary() {
            const low = this.items.filter(i => i.qty > 0 && i.qty <= i.threshold).length, out = this.items.filter(i => i.qty <= 0).length;
            const value = this.items.reduce((s, i) => s + Math.max(0, i.qty) * (i.price || 0), 0);
            return { products: this.items.length, low, out, value, priced: this.items.some(i => i.price) };
        },
        get filtered() {
            const q = this.q.trim().toLowerCase();
            return this.items.filter(i => (this.tab === 'all' || (this.tab === 'low' ? i.qty > 0 && i.qty <= i.threshold : i.qty <= 0))
                && (!this.category || i.category === this.category)
                && (!q || (i.product + ' ' + i.variant + ' ' + (i.sku || '')).toLowerCase().includes(q)));
        },
        state(i) { return i.qty <= 0 ? ['bad', 'Out of stock'] : (i.threshold != null && i.qty <= i.threshold) ? ['warn', 'Below par'] : ['ok', 'In stock']; },
        width(i) { return Math.min(100, Math.max(0, i.qty) / this.maxLevel * 100); },
        tick(i) { return i.threshold == null ? null : Math.min(100, i.threshold / this.maxLevel * 100); },
        openReceive(variantId = '') {
            this.form = { variant_id: variantId, quantity: '', batch_code: 'WEB-' + new Date().toISOString().slice(0, 10).replace(/-/g, ''), expiration_date: '' };
            this.formError = null;
            window.dispatchEvent(new CustomEvent('open-modal', { detail: 'receive-stock' }));
        },
        async receive() {
            if (this.busy) return;
            if (!this.live) { this.formError = 'Receiving stock needs the Melai Nuts app database.'; return; }
            const item = this.items.find(i => i.variant_id === this.form.variant_id);
            const qty = parseInt(this.form.quantity, 10);
            if (!item) { this.formError = 'Choose a product.'; return; }
            if (!(qty > 0)) { this.formError = 'Enter a quantity of at least 1.'; return; }
            this.busy = true; this.formError = null;
            const before = item.qty;
            item.qty = before + qty; // optimistic: the bar animates up now
            window.dispatchEvent(new CustomEvent('close-modal', { detail: 'receive-stock' }));
            try {
                const res = await api(receiveUrl, { method: 'POST', body: { ...this.form, quantity: qty, branch } });
                if (res.item) Object.assign(item, { qty: res.item.quantity, threshold: res.item.restock_threshold, batched: res.item.batched_quantity });
                this.flash = item.variant_id; setTimeout(() => this.flash = null, 1600);
                Alpine.store('ui').toast(res.message + ' Every number follows.');
                changed('stock');
            } catch (e) {
                item.qty = before;
                Alpine.store('ui').toast(e.message, 'bad');
            } finally { this.busy = false; }
        },
        csv() {
            download(`count-sheet-${(branchName || 'branch').replace(/\W+/g, '-').toLowerCase()}-${new Date().toISOString().slice(0, 10)}.csv`,
                [['product', 'variant', 'sku', 'category', 'on_hand', 'restock_at', 'counted']].concat(this.filtered.map(i => [i.product, i.variant, i.sku, i.category, i.qty, i.threshold, ''])));
        },
    };
}

// ---------------------------------------------------------------------------------------------
// New order (in-store sale through the app's POS function)
// ---------------------------------------------------------------------------------------------
const newSaleKey = () => (crypto.randomUUID?.() || String(Date.now()) + Math.random());

/**
 * The sale's idempotency key. The database returns the recorded sale for the same key + same
 * details and refuses the same key with different details. So a changed sale (lines, branch,
 * method, cash) gets a new key, EXCEPT after a request whose outcome is unknown (network error,
 * timeout, 5xx): the sale may already be recorded, and only the same key lets the database say so
 * instead of recording a second one.
 */
export function rotateSaleKey(state) {
    if (state.outcomeUnknown) return state.key;
    state.key = newSaleKey();
    return state.key;
}

/** True when a failed request may still have been recorded (it never got a clear answer). */
export const outcomeUnknown = (e) => !e?.status || e.status === 408 || e.status >= 500;

function newOrderComponent({ branches, live, branchesUrl, catalogUrl, storeUrl }) {
    return {
        branches, live, branch: branches[0]?.id || '', catalog: [], loadingCatalog: false, lines: [], method: 'cash', reference: '', cash: '',
        busy: false, error: null, key: null, outcomeUnknown: false, pick: '',
        init() {
            window.addEventListener('open-modal', (e) => { if (e.detail === 'new-order') this.reset(); });
            this.$watch('branch', () => { this.lines = []; this.loadCatalog(); rotateSaleKey(this); });
            this.$watch('lines', () => rotateSaleKey(this), { deep: true });
            this.$watch('method', () => rotateSaleKey(this));
            this.$watch('cash', () => rotateSaleKey(this));
            this.$watch('reference', () => rotateSaleKey(this));
        },
        reset() {
            this.lines = []; this.method = 'cash'; this.reference = ''; this.cash = ''; this.error = null; this.pick = '';
            this.outcomeUnknown = false;
            this.key = newSaleKey();
            if (this.live && !this.branches.length) {
                api(branchesUrl).then((list) => { this.branches = list; this.branch = list[0]?.id || ''; }).catch((e) => { this.error = e.message; });
            } else if (this.live && !this.catalog.length) this.loadCatalog();
        },
        async loadCatalog() {
            if (!this.live || !this.branch) return;
            this.loadingCatalog = true;
            try { this.catalog = await api(catalogUrl + '?branch=' + encodeURIComponent(this.branch)); }
            catch (e) { this.error = e.message; }
            finally { this.loadingCatalog = false; }
        },
        variant(id) { return this.catalog.find(c => c.variant_id === id); },
        add() {
            const v = this.variant(this.pick);
            if (!v) return;
            const line = this.lines.find(l => l.variant_id === v.variant_id);
            if (line) line.quantity++; else this.lines.push({ variant_id: v.variant_id, quantity: 1 });
            this.pick = '';
        },
        get total() { return this.lines.reduce((s, l) => s + (this.variant(l.variant_id)?.price || 0) * (parseInt(l.quantity, 10) || 0), 0); },
        async submit() {
            if (this.busy) return;
            if (!this.lines.length) { this.error = 'Add at least one product.'; return; }
            this.busy = true; this.error = null;
            try {
                const res = await api(storeUrl, { method: 'POST', body: {
                    branch: this.branch, items: this.lines.map(l => ({ variant_id: l.variant_id, quantity: parseInt(l.quantity, 10) })),
                    method: this.method, reference: this.reference || null, cash_received: this.method === 'cash' && this.cash !== '' ? Number(this.cash) : null, key: this.key } });
                const already = Boolean(res.result?.already_recorded);
                window.dispatchEvent(new CustomEvent('close-modal', { detail: 'new-order' }));
                const change = Number(res.result?.change || 0);
                // "Already recorded" is always shown, even with notifications turned off.
                Alpine.store('ui').toast(res.message + (change > 0 ? ' Change: ' + peso(change) + '.' : '') + ' Every number follows.', 'ok', already);
                // A finished sale's key must never be used again.
                this.reset();
                this.catalog = [];
                changed('orders');
            } catch (e) {
                if (outcomeUnknown(e)) this.outcomeUnknown = true;
                this.error = e.message;
            }
            finally { this.busy = false; }
        },
    };
}

// ---------------------------------------------------------------------------------------------
// Dashboard: branch / staff blocks re-read every minute (and after a change)
// ---------------------------------------------------------------------------------------------
// Re-reads this page's content (as a fragment) and swaps in the numbers, so new orders,
// payments, refunds and stock movements show up without a reload. A failed refresh keeps the last
// real numbers on screen and says so; it never invents values.
function liveRefreshComponent(seconds) {
    return {
        failed: false, busy: false, updatedLabel: '',
        init() {
            this.timer = setInterval(() => { if (!document.hidden && Alpine.store('ui').liveRefresh) this.refresh(); }, seconds * 1000);
            this.onChange = () => this.refresh(true);
            window.addEventListener('melai:changed', this.onChange);
        },
        destroy() { clearInterval(this.timer); window.removeEventListener('melai:changed', this.onChange); },
        async refresh(fresh = false) {
            if (this.busy || !this.$el.isConnected) return; this.busy = true;
            try {
                const url = new URL(window.location.href);
                if (fresh) url.searchParams.set('fresh', '1');
                const r = await fetch(url, { headers: { Accept: 'text/html', 'X-Melai-Fragment': '1', 'X-Requested-With': 'live-refresh' }, credentials: 'same-origin' });
                if (!r.ok) throw new Error(r.status);
                const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
                const fresh2 = doc.getElementById('live-dashboard');
                if (!fresh2) throw new Error('no content');
                fresh2.querySelectorAll(':scope > section').forEach((sec, i) => {
                    const cur = this.$el.querySelectorAll(':scope > section')[i];
                    if (cur) cur.replaceWith(document.importNode(sec, true));
                });
                this.failed = false;
                this.updatedLabel = new Date().toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit', second: '2-digit' });
            } catch (e) { this.failed = true; } finally { this.busy = false; }
        },
    };
}

// ---------------------------------------------------------------------------------------------
// In-page navigation: sidebar (and card / palette) links swap only the page content. The sidebar,
// CSS and JS stay loaded; Alpine starts the new content's components by itself. Any problem
// (error status, signed out, a page with its own scripts) falls back to a normal navigation.
// ---------------------------------------------------------------------------------------------
const fragments = new Map(); // url -> { at, promise }   (started on pointerdown, ~15 s)
const FRAG_TTL = 15000;
let navToken = 0;
let lastInteraction = 0;

async function fetchFragment(url, fresh = false) {
    const u = new URL(url, location.href);
    if (fresh) u.searchParams.set('fresh', '1');
    const r = await fetch(u, { headers: { 'X-Melai-Fragment': '1', Accept: 'text/html' }, credentials: 'same-origin' });
    if (!r.ok || !(r.headers.get('content-type') || '').includes('text/html')) throw new Error('status ' + r.status);
    const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
    const frag = doc.querySelector('[data-fragment]');
    if (!frag) throw new Error('not a page fragment');          // e.g. redirected to the login page
    if (frag.querySelector('script')) throw new Error('page has its own scripts');
    return { frag, stale: r.headers.get('X-Melai-Stale') === '1' };
}

function prefetch(url) {
    const hit = fragments.get(url);
    if (hit && Date.now() - hit.at < FRAG_TTL) return;
    fragments.set(url, { at: Date.now(), promise: fetchFragment(url).catch(() => null) });
}

function swap(frag, { animate = true } = {}) {
    const main = document.querySelector('.main-inner');
    main.innerHTML = frag.innerHTML;          // Alpine cleans up the old components and starts the new ones
    main.classList.remove('is-swapping');
    if (animate) { main.classList.remove('page-enter'); void main.offsetWidth; main.classList.add('page-enter'); }
    if (frag.dataset.title) document.title = frag.dataset.title;
    document.querySelectorAll('.nav-item').forEach(a => {
        const on = a.dataset.key === frag.dataset.nav;
        a.classList.toggle('is-active', on);
        on ? a.setAttribute('aria-current', 'page') : a.removeAttribute('aria-current');
    });
}

function progress(on) {
    let bar = document.querySelector('.nav-progress');
    if (!bar) { bar = Object.assign(document.createElement('div'), { className: 'nav-progress' }); document.body.append(bar); }
    if (on) { bar.style.opacity = '1'; bar.style.width = '0'; requestAnimationFrame(() => { bar.style.width = '70%'; }); }
    else { bar.style.width = '100%'; setTimeout(() => { bar.style.opacity = '0'; bar.style.width = '0'; }, 250); }
}

export async function navigate(url, { push = true, fromShell = false } = {}) {
    const token = ++navToken;
    const main = document.querySelector('.main-inner');
    if (!main) { location.assign(url); return; }
    progress(true);
    if (!fromShell) main.classList.add('is-swapping');
    let res = null;
    try {
        const hit = fragments.get(url);
        res = (hit && Date.now() - hit.at < FRAG_TTL ? await hit.promise : null) || await fetchFragment(url);
    } catch (e) {
        res = null;
    }
    fragments.delete(url);
    if (token !== navToken) return;           // the user clicked somewhere else meanwhile
    progress(false);
    if (!res) {                               // fall back to a normal page load
        const u = new URL(url, location.href);
        if (fromShell) { u.searchParams.set('full', '1'); location.replace(u); } else location.assign(u);
        return;
    }
    if (push) history.pushState({ soft: true }, '', url);
    swap(res.frag, { animate: !fromShell });
    if (!fromShell) document.getElementById('main')?.scrollTo({ top: 0 });
    Alpine.store('ui').nav = false;

    // Served from a stale cache: fetch the fresh page in the background and show it if the user has
    // not started working on this one (no click or key press since it appeared).
    if (res.stale) {
        const shownAt = Date.now();
        fetchFragment(url, true).then((r) => {
            if (token === navToken && lastInteraction < shownAt && r && new URL(url, location.href).href === location.href) swap(r.frag, { animate: false });
        }).catch(() => {});
    }
}

const SOFT_LINKS = 'a.nav-item, a.side-brand, a.ui-card, a[data-soft]';

function softTarget(e) {
    const a = e.target.closest?.(SOFT_LINKS);
    if (!a || (a.target && a.target !== '_self') || a.hasAttribute('download') || a.dataset.hard !== undefined) return null;
    const u = new URL(a.href, location.href);
    return u.origin === location.origin ? u : null;
}

function bootSoftNavigation() {
    history.replaceState({ soft: true }, '', location.href);
    document.addEventListener('click', (e) => {
        if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        const u = softTarget(e);
        if (!u) return;
        e.preventDefault();
        if (u.href === location.href) { Alpine.store('ui').nav = false; return; }
        navigate(u.href);
    });
    // SPEED: start loading only when the button is actually pressed (pointerdown comes ~100 ms before
    // click). Prefetching on HOVER sent a request for every sidebar link the mouse crossed; the local
    // server (php artisan serve) answers ONE request at a time, so the page you clicked waited
    // behind pages you never opened (15-30 s loads).
    document.addEventListener('pointerdown', (e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        const u = softTarget(e);
        if (u && u.href !== location.href) prefetch(u.href);
    });
    window.addEventListener('popstate', () => navigate(location.href, { push: false }));
    ['pointerdown', 'keydown'].forEach(t => document.addEventListener(t, () => { lastInteraction = Date.now(); }, true));
    window.addEventListener('melai:changed', () => fragments.clear());
}
