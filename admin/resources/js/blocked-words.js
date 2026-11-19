// Blocked words (profanity) check for reviews and order special instructions, in the browser.
// The SAME algorithm as App\Support\BlockedWords (PHP), lib/core/moderation/blocked_words.dart
// (app) and public.contains_blocked_words (database). The list itself comes from the page
// (moderation/blocked_words.json, printed by the server), so there is one list to edit.
// scripts/test_blocked_words.py runs moderation/test_cases.json against every copy.

const ACCENTS = { á: 'a', à: 'a', â: 'a', ä: 'a', ã: 'a', é: 'e', è: 'e', ê: 'e', ë: 'e', í: 'i', ì: 'i', î: 'i', ï: 'i',
    ó: 'o', ò: 'o', ô: 'o', ö: 'o', õ: 'o', ú: 'u', ù: 'u', û: 'u', ü: 'u', ñ: 'n' };
const LEET = { '@': 'a', 4: 'a', 1: 'i', '!': 'i', '|': 'i', 0: 'o', 3: 'e', $: 's', 5: 's', 7: 't' };

const collapse = (s) => s.replace(/(.)\1+/g, '$1');
const mapChars = (s, table) => [...s].map((ch) => table[ch] ?? ch).join('');
const lettersOnly = (s) => s.replace(/[^a-z]+/g, '');
const parts = (s) => s.split(/[^a-z]+/).filter(Boolean);

/** Returns contains(text) -> boolean for the given list ({ words, roots, phrases, allow }). */
export function makeBlockedWordsChecker(list) {
    const clean = (v) => (Array.isArray(v) ? v : []).map((w) => String(w).trim().toLowerCase()).filter(Boolean);
    const words = clean(list.words);
    const allow = new Set(clean(list.allow));
    const wordMin = new Map();
    words.forEach((w) => { const k = collapse(w); wordMin.set(k, Math.min(wordMin.get(k) ?? Infinity, w.length)); });
    const roots = clean(list.roots).map(collapse);
    const longWords = words.filter((w) => w.length >= 4).map(collapse);
    const phrases = clean(list.phrases).map((p) => p.split(/\s+/).map(collapse).join(' '));

    const isWord = (w) => {
        if (!w || allow.has(w)) return false;
        const forms = [w];
        if (w.length >= 4 && w.endsWith('s')) forms.push(w.slice(0, -1));
        if (w.length >= 5 && w.endsWith('es')) forms.push(w.slice(0, -2));
        for (const f of forms) {
            const min = wordMin.get(collapse(f));
            if (min !== undefined && f.length >= min) return true;
        }
        const cw = collapse(w);
        return roots.some((r) => cw.includes(r));
    };

    const sequences = (text) => {
        const t = mapChars(text.toLowerCase(), ACCENTS);
        const plain = []; const leet = []; const squeezed = [];
        t.split(/\s+/).filter(Boolean).forEach((chunk) => {
            const variants = [chunk];
            if (/[a-z@$!|]/.test(chunk)) variants.push(mapChars(chunk, LEET));
            variants.forEach((v, i) => {
                const p = parts(v);
                if (i === 0) {
                    plain.push(...p);
                    if (variants.length === 1) leet.push(...p);
                } else {
                    leet.push(...p);
                }
                squeezed.push(lettersOnly(v));
            });
        });
        return [plain, leet, squeezed];
    };

    const runs = (seq) => {
        const out = []; let run = [];
        [...seq, ''].forEach((tok) => {
            if (tok.length === 1) { run.push(tok); return; }
            if (run.length >= 3) out.push(run.join(''));
            run = [];
        });
        return out;
    };

    return (text) => {
        if (typeof text !== 'string' || text.trim() === '') return false;
        const [plain, leet, squeezed] = sequences(text);
        if ([...plain, ...leet, ...squeezed].some(isWord)) return true;
        for (const seq of [plain, leet]) {
            for (const joined of runs(seq)) {
                if (allow.has(joined)) continue;
                const cj = collapse(joined);
                if (isWord(joined) || longWords.some((x) => cj.includes(x))) return true;
            }
            const line = ` ${seq.map(collapse).join(' ')} `;
            if (phrases.some((p) => line.includes(` ${p} `))) return true;
        }
        return false;
    };
}
