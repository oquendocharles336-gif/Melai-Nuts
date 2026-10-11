// Lightweight inline-SVG charts for the admin UI (no chart library).
// - lineChart: monotone smooth curve, accent area fill, nearest-point hover with a guide line,
//   a dot and a dark tooltip. Redraws (with a draw-in animation) whenever its data changes.
// - barChart: grouped bars, this period (accent) vs the previous period (grey); the hovered bar
//   turns near-black and a tooltip shows both values.
// Colours come from CSS variables, so both re-tint with the theme and the accent swatch.

import { peso, shortDate, longDate } from './format';

/** Fritsch–Carlson monotone cubic: smooth, never overshoots between points. */
export function monotonePath(pts) {
    const n = pts.length;
    if (n === 0) return '';
    if (n === 1) return `M${pts[0][0]},${pts[0][1]}`;
    const dx = [], m = [], t = new Array(n);
    for (let i = 0; i < n - 1; i++) {
        dx[i] = pts[i + 1][0] - pts[i][0];
        m[i] = dx[i] === 0 ? 0 : (pts[i + 1][1] - pts[i][1]) / dx[i];
    }
    t[0] = m[0]; t[n - 1] = m[n - 2];
    for (let i = 1; i < n - 1; i++) t[i] = m[i - 1] * m[i] <= 0 ? 0 : (m[i - 1] + m[i]) / 2;
    for (let i = 0; i < n - 1; i++) {
        if (m[i] === 0) { t[i] = 0; t[i + 1] = 0; continue; }
        const a = t[i] / m[i], b = t[i + 1] / m[i], s = a * a + b * b;
        if (s > 9) { const k = 3 / Math.sqrt(s); t[i] = k * a * m[i]; t[i + 1] = k * b * m[i]; }
    }
    let d = `M${pts[0][0].toFixed(2)},${pts[0][1].toFixed(2)}`;
    for (let i = 0; i < n - 1; i++) {
        const h = dx[i] / 3;
        d += `C${(pts[i][0] + h).toFixed(2)},${(pts[i][1] + t[i] * h).toFixed(2)},${(pts[i + 1][0] - h).toFixed(2)},${(pts[i + 1][1] - t[i + 1] * h).toFixed(2)},${pts[i + 1][0].toFixed(2)},${pts[i + 1][1].toFixed(2)}`;
    }
    return d;
}

/** A "nice" axis maximum and ticks (1, 2, 2.5, 5 × 10^n). */
export function niceTicks(max, count = 4) {
    if (!(max > 0)) return { max: 1, ticks: [0, 1] };
    const raw = max / count, pow = Math.pow(10, Math.floor(Math.log10(raw)));
    const step = [1, 2, 2.5, 5, 10].map(s => s * pow).find(s => s >= raw);
    const top = Math.ceil(max / step) * step;
    const ticks = [];
    for (let v = 0; v <= top + 1e-9; v += step) ticks.push(v);
    return { max: top, ticks };
}

export function sparkPath(values, w = 84, h = 30) {
    const v = (values || []).map(Number);
    if (v.length < 2) return '';
    const max = Math.max(...v), min = Math.min(...v), span = max - min || 1;
    const pts = v.map((y, i) => [i / (v.length - 1) * w, h - 3 - (y - min) / span * (h - 6)]);
    return monotonePath(pts);
}

export function lineChart() {
    return {
        w: 640, h: 260, pad: { l: 52, r: 12, t: 12, b: 28 },
        series: [], yTicks: [], yMax: 1, linePath: '', areaPath: '', xLabels: [], pts: [],
        hover: null, drawing: false, empty: false,
        init() {
            const ro = new ResizeObserver(([e]) => { const nw = Math.round(e.contentRect.width); if (nw && nw !== this.w) { this.w = nw; this.layout(false); } });
            ro.observe(this.$el);
            this.$cleanup?.(() => ro.disconnect());
        },
        /** Called from x-effect with [{date, value}] */
        draw(series) {
            this.series = Array.isArray(series) ? series.map(p => ({ date: p.date, value: Number(p.value) || 0 })) : [];
            this.layout(true);
        },
        layout(animate) {
            const s = this.series, { l, r, t, b } = this.pad, iw = Math.max(10, this.w - l - r), ih = this.h - t - b;
            this.empty = !s.length || s.every(p => p.value === 0);
            const nice = niceTicks(Math.max(...s.map(p => p.value), 0));
            this.yMax = nice.max;
            this.yTicks = nice.ticks.map(v => ({ v, y: t + ih - v / nice.max * ih, label: peso(v, true) }));
            this.pts = s.map((p, i) => [l + (s.length === 1 ? iw / 2 : i / (s.length - 1) * iw), t + ih - p.value / nice.max * ih]);
            this.linePath = monotonePath(this.pts);
            this.areaPath = this.pts.length > 1 ? `${this.linePath}L${this.pts[this.pts.length - 1][0]},${t + ih}L${this.pts[0][0]},${t + ih}Z` : '';
            const want = Math.max(2, Math.min(7, Math.floor(iw / 90)));
            const step = Math.max(1, Math.round((s.length - 1) / (want - 1)));
            this.xLabels = s.map((p, i) => ({ i, x: this.pts[i][0], label: shortDate(p.date) }))
                .filter(o => o.i % step === 0 || o.i === s.length - 1)
                .filter((o, k, arr) => k === arr.length - 1 || arr[arr.length - 1].x - o.x > 46 || o.i === arr[arr.length - 1].i);
            if (this.hover !== null && this.hover >= s.length) this.hover = null;
            if (animate) { this.drawing = false; requestAnimationFrame(() => requestAnimationFrame(() => { this.drawing = true; })); }
        },
        move(ev) {
            if (!this.pts.length) return;
            const rect = this.$refs.svg.getBoundingClientRect();
            const x = (ev.clientX - rect.left) * (this.w / rect.width);
            let best = 0, dist = Infinity;
            this.pts.forEach(([px], i) => { const d = Math.abs(px - x); if (d < dist) { dist = d; best = i; } });
            this.hover = best;
        },
        get gridSvg() { return this.yTicks.map(t => `<line x1="${this.pad.l}" x2="${this.w - this.pad.r}" y1="${t.y}" y2="${t.y}"/>`).join(''); },
        get yAxisSvg() { return this.yTicks.map(t => `<text x="${this.pad.l - 10}" y="${t.y + 4}" text-anchor="end">${t.label}</text>`).join(''); },
        get xAxisSvg() {
            const last = this.series.length - 1;
            return this.xLabels.map(l => `<text x="${l.x}" y="${this.h - 6}" text-anchor="${l.i === 0 ? 'start' : l.i === last ? 'end' : 'middle'}">${l.label}</text>`).join('');
        },
        get tip() {
            if (this.hover === null || !this.series[this.hover]) return null;
            const [x, y] = this.pts[this.hover];
            return { x, y, value: peso(this.series[this.hover].value, true), date: longDate(this.series[this.hover].date),
                full: peso(this.series[this.hover].value) };
        },
    };
}

export function barChart() {
    return {
        w: 640, h: 260, pad: { l: 52, r: 8, t: 12, b: 28 },
        rows: [], bars: [], yTicks: [], hover: null, empty: false,
        init() {
            const ro = new ResizeObserver(([e]) => { const nw = Math.round(e.contentRect.width); if (nw && nw !== this.w) { this.w = nw; this.layout(); } });
            ro.observe(this.$el);
        },
        /** [{label, cur, prev, prevLabel}] */
        draw(rows) { this.rows = Array.isArray(rows) ? rows : []; this.layout(); },
        layout() {
            const { l, r, t, b } = this.pad, iw = Math.max(10, this.w - l - r), ih = this.h - t - b, n = this.rows.length;
            this.empty = !n || this.rows.every(x => !x.cur && !x.prev);
            const nice = niceTicks(Math.max(0, ...this.rows.map(x => Math.max(x.cur || 0, x.prev || 0))));
            this.yTicks = nice.ticks.map(v => ({ v, y: t + ih - v / nice.max * ih, label: peso(v, true) }));
            const slot = iw / Math.max(1, n), bw = Math.max(3, Math.min(22, slot * 0.32)), gap = Math.max(1, bw * 0.15);
            const every = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(iw / 70))));
            this.bars = this.rows.map((x, i) => {
                const cx = l + slot * i + slot / 2, hc = (x.cur || 0) / nice.max * ih, hp = (x.prev || 0) / nice.max * ih;
                return { i, cx, label: x.label, showLabel: i % every === 0,
                    prev: { x: cx - bw - gap / 2, y: t + ih - hp, w: bw, h: Math.max(hp, x.prev ? 1 : 0) },
                    cur: { x: cx + gap / 2, y: t + ih - hc, w: bw, h: Math.max(hc, x.cur ? 1 : 0) },
                    hitX: l + slot * i, hitW: slot };
            });
        },
        get gridSvg() { return this.yTicks.map(t => `<line x1="${this.pad.l}" x2="${this.w - this.pad.r}" y1="${t.y}" y2="${t.y}"/>`).join(''); },
        get yAxisSvg() { return this.yTicks.map(t => `<text x="${this.pad.l - 10}" y="${t.y + 4}" text-anchor="end">${t.label}</text>`).join(''); },
        get barsSvg() {
            const esc = (x) => String(x).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
            return this.bars.map(b => `<rect class="bar-prev" x="${b.prev.x}" y="${b.prev.y}" width="${b.prev.w}" height="${b.prev.h}" rx="3"/>`
                + `<rect class="bar-cur${this.hover === b.i ? ' is-hot' : ''}" x="${b.cur.x}" y="${b.cur.y}" width="${b.cur.w}" height="${b.cur.h}" rx="3"/>`
                + (b.showLabel ? `<text x="${b.cx}" y="${this.h - 6}" text-anchor="middle">${esc(b.label)}</text>` : '')).join('');
        },
        move(ev) {
            if (!this.bars.length) return;
            const rect = this.$refs.svg.getBoundingClientRect(), x = (ev.clientX - rect.left) * (this.w / rect.width);
            const hit = this.bars.find(b => x >= b.hitX && x < b.hitX + b.hitW);
            this.hover = hit ? hit.i : null;
        },
        get tip() {
            if (this.hover === null || !this.rows[this.hover]) return null;
            const r = this.rows[this.hover], b = this.bars[this.hover];
            return { x: b.cx, y: Math.min(b.cur.y, b.prev.y), value: peso(r.cur || 0, true), label: r.label, prev: r.prev == null ? null : peso(r.prev, true) };
        },
    };
}
