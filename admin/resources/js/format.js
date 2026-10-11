// Number and date formatting shared by the admin UI (Philippine peso, Asia/Manila dates).

const nf0 = new Intl.NumberFormat('en-PH', { maximumFractionDigits: 0 });
const nf2 = new Intl.NumberFormat('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function peso(n, compact = false) {
    if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
    const v = Number(n);
    if (compact) {
        const a = Math.abs(v);
        if (a >= 1e6) return '₱' + trim(v / 1e6) + 'M';
        if (a >= 1e3) return '₱' + trim(v / 1e3) + 'k';
        return '₱' + nf0.format(v);
    }
    return '₱' + nf2.format(v);
}
function trim(x) { return (Math.round(x * 10) / 10).toString(); }

export function int(n) { return n === null || n === undefined ? '—' : nf0.format(Number(n)); }

export function pct(n, signed = true) {
    if (n === null || n === undefined) return '—';
    const v = Number(n);
    return (signed && v > 0 ? '+' : '') + (Math.round(v * 10) / 10).toFixed(1) + '%';
}

const tz = 'Asia/Manila';
function asDate(d) { return typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d) ? new Date(d + 'T12:00:00+08:00') : new Date(d); }
export function shortDate(d) { return asDate(d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: tz }); }
export function longDate(d) { return asDate(d).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: tz }); }
export function dateTime(d) {
    if (!d) return '—';
    return asDate(d).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: tz });
}
export function ago(d) {
    if (!d) return '—';
    const s = Math.round((Date.now() - asDate(d).getTime()) / 1000);
    if (s < 45) return 'just now';
    if (s < 3600) return Math.round(s / 60) + ' min ago';
    if (s < 86400) return Math.round(s / 3600) + ' h ago';
    if (s < 86400 * 7) return Math.round(s / 86400) + ' d ago';
    return shortDate(d);
}
export function initials(name) {
    const parts = String(name || '?').replace(/[^\p{L}\p{N} ]/gu, ' ').trim().split(/\s+/).filter(Boolean);
    return ((parts[0]?.[0] || '?') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase();
}
