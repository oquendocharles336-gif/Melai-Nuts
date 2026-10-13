// Pagination for every list on the website.
//  - Server lists (Payments, Refunds, All users, Activity logs) render resources/views/pagination/melai.blade.php.
//  - Plain server-rendered tables are paged here, in the browser (enhanceTables).
//  - Alpine lists (Orders, Stock) mix in withPager().
// All three draw the same bar and share one "Rows" choice, kept in the melai_per_page cookie so the
// server lists use it too (App\Support\ListTools::perPage).

import { int } from './format';

export const PAGE_SIZES = [10, 25, 50, 100];
const COOKIE = 'melai_per_page';

export function pageSize() {
    const m = document.cookie.match(/(?:^|;\s*)melai_per_page=(\d+)/);
    const n = m ? parseInt(m[1], 10) : PAGE_SIZES[0];
    return PAGE_SIZES.includes(n) ? n : PAGE_SIZES[0];
}

export function setPageSize(n) {
    n = parseInt(n, 10);
    if (!PAGE_SIZES.includes(n)) n = PAGE_SIZES[0];
    document.cookie = `${COOKIE}=${n}; path=/; max-age=31536000; SameSite=Lax`;
    window.dispatchEvent(new CustomEvent('melai:pagesize', { detail: n }));
    return n;
}

/** Page numbers to show (null = "…"): first, last, current ±1. Same rule as ListTools::pageWindow(). */
export function pageWindow(current, last) {
    const out = [];
    let prev = 0;
    for (let n = 1; n <= last; n++) {
        if (n === 1 || n === last || Math.abs(n - current) <= 1 || (current <= 3 && n <= 4) || (current >= last - 2 && n >= last - 3)) {
            if (prev && n - prev > 1) out.push(n - prev === 2 ? n - 1 : null);
            out.push(n);
            prev = n;
        }
    }
    return out;
}

function pagerHtml(page, last, total, size) {
    const from = (page - 1) * size + 1, to = Math.min(total, page * size);
    const btn = (n, label, aria, disabled) => `<button type="button" class="pager-btn" data-page="${n}" aria-label="${aria}"${disabled ? ' disabled' : ''}>${label}</button>`;
    const nums = pageWindow(page, last).map(n => n === null ? '<span class="pager-gap" aria-hidden="true">…</span>'
        : n === page ? `<span class="pager-btn is-on" aria-current="page">${n}</span>` : btn(n, n, 'Page ' + n, false)).join('');
    const opts = PAGE_SIZES.map(n => `<option value="${n}"${n === size ? ' selected' : ''}>${n}</option>`).join('');
    return `<span class="pager-info">${int(from)}–${int(to)} of ${int(total)}</span>`
        + `<div class="pager-pages">${btn(page - 1, '‹', 'Previous page', page <= 1)}${nums}${btn(page + 1, '›', 'Next page', page >= last)}</div>`
        + `<label class="pager-size">Rows <select class="select" data-pager-size-client aria-label="Rows per page">${opts}</select></label>`;
}

// Current page of each in-page table, per URL, so a live refresh or a page-size change keeps your place.
const tablePages = new Map();

function pageableTables(root) {
    return [...root.querySelectorAll('table')].filter(t => !t.closest('[data-no-paginate]') && t.tBodies.length
        && !t.tBodies[0].querySelector('template'));          // Alpine-drawn rows page themselves
}

/** Adds (or refreshes) a pager under every server-rendered table with rows inside root. */
export function enhanceTables(root) {
    if (!root) return;
    pageableTables(root).forEach((table, i) => {
        const key = location.pathname + location.search + '#' + i;
        // Data rows only: not pinned rows, not "Nothing here" / loading rows (one cell spanning the table).
        const rows = [...table.tBodies[0].rows].filter(r => !r.hasAttribute('data-pin') && !r.querySelector('td.empty')
            && !(r.cells.length === 1 && r.cells[0].colSpan > 1));
        const box = table.closest('.ui-table-wrap, .table-wrap') || table;
        let bar = table._pager;
        if (!rows.length) {
            rows.forEach(r => r.classList.remove('pg-hide'));
            bar?.remove(); table._pager = null;
            return;
        }
        if (!bar || !bar.isConnected) {
            bar = Object.assign(document.createElement('nav'), { className: 'pager' });
            bar.setAttribute('aria-label', 'Pages');
            bar.dataset.pagerClient = '';
            box.after(bar);
            table._pager = bar;
        }
        const render = () => {
            const size = pageSize(), last = Math.max(1, Math.ceil(rows.length / size));
            const page = Math.min(Math.max(1, tablePages.get(key) || 1), last);
            rows.forEach((r, k) => r.classList.toggle('pg-hide', k < (page - 1) * size || k >= page * size));
            bar.innerHTML = pagerHtml(page, last, rows.length, size);
        };
        bar._go = (n, scroll) => { tablePages.set(key, n); render(); if (scroll && box.getBoundingClientRect().top < 0) box.scrollIntoView({ block: 'start', behavior: 'smooth' }); };
        render();
    });
}

/** Clicks and "Rows" changes on the in-page pagers (one listener for the whole page). */
export function bootPagers() {
    document.addEventListener('click', (e) => {
        const b = e.target.closest?.('[data-pager-client] [data-page]');
        if (!b || b.disabled) return;
        b.blur();
        b.closest('[data-pager-client]')._go?.(parseInt(b.dataset.page, 10), true);
    });
    document.addEventListener('change', (e) => {
        if (e.target.matches?.('[data-pager-size-client]')) setPageSize(e.target.value);
    });
    window.addEventListener('melai:pagesize', () => {
        tablePages.clear();
        enhanceTables(document.querySelector('.main-inner'));
    });
}

/**
 * Adds paging to an Alpine component whose full (filtered) list is the getter/array `listKey`:
 * pageRows, pageCount, curPage, pageList, pageInfo, goPage(n). Draw it with <x-pager-alpine list="..." />.
 */
export function withPager(obj, listKey) {
    const mix = {
        page: 1,
        perPage: pageSize(),
        get pageCount() { return Math.max(1, Math.ceil(this[listKey].length / this.perPage)); },
        get curPage() { return Math.min(Math.max(1, this.page), this.pageCount); },
        get pageRows() { const p = this.curPage; return this[listKey].slice((p - 1) * this.perPage, p * this.perPage); },
        get pageList() { return pageWindow(this.curPage, this.pageCount); },
        get pageInfo() {
            const n = this[listKey].length, p = this.curPage;
            return n ? `${int((p - 1) * this.perPage + 1)}–${int(Math.min(n, p * this.perPage))} of ${int(n)}` : '';
        },
        goPage(n) {
            document.activeElement?.blur?.();
            this.page = Math.max(1, Math.min(n, this.pageCount));
            const box = this.$el.querySelector('.ui-table-wrap');
            if (box && box.getBoundingClientRect().top < 0) box.scrollIntoView({ block: 'start', behavior: 'smooth' });
        },
        setPerPage(n) { this.perPage = setPageSize(n); this.page = 1; },
    };
    Object.defineProperties(obj, Object.getOwnPropertyDescriptors(mix));
    const init = obj.init;
    obj.init = function () {
        this._onSize = (e) => { this.perPage = e.detail; this.page = 1; };
        window.addEventListener('melai:pagesize', this._onSize);
        return init?.call(this);
    };
    const destroy = obj.destroy;
    obj.destroy = function () { window.removeEventListener('melai:pagesize', this._onSize); return destroy?.call(this); };
    return obj;
}
