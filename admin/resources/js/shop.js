// Melai Nuts shop: small progressive enhancements. Every action is a normal form first, so the
// shop works without JavaScript; this adds in-place "Add to cart", quantity buttons, the location
// prompt for the pickup branch, the password checklist and the payment-status check.

const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content ?? '';

function toast(message, { tone = 'ok', link = null } = {}) {
    let el = document.getElementById('s-toast');
    if (!el) {
        el = document.createElement('div');
        el.id = 's-toast';
        el.className = 's-toast';
        el.setAttribute('role', 'status');
        el.setAttribute('aria-live', 'polite');
        document.body.appendChild(el);
    }
    el.classList.toggle('bad', tone === 'bad');
    el.textContent = message;
    if (link) {
        const a = document.createElement('a');
        a.href = link.href;
        a.textContent = link.label;
        el.appendChild(a);
    }
    requestAnimationFrame(() => el.classList.add('show'));
    clearTimeout(el._t);
    el._t = setTimeout(() => el.classList.remove('show'), 4200);
}

function setBadge(count) {
    document.querySelectorAll('[data-cart-count]').forEach((badge) => {
        badge.textContent = String(count);
        badge.hidden = count <= 0;
        badge.classList.remove('bump');
        void badge.offsetWidth; // restart the animation
        badge.classList.add('bump');
    });
}

async function postJson(url, body, method = 'POST') {
    const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-TOKEN': csrf(), 'X-Requested-With': 'XMLHttpRequest' },
        body: JSON.stringify(body),
        credentials: 'same-origin',
    });
    let data = {};
    try { data = await res.json(); } catch { /* empty body */ }
    if (res.status === 401 && data.signed_out) window.location.href = '/shop/login';
    if (!res.ok) throw new Error(data.message || 'Something went wrong. Please try again.');
    return data;
}

// ---- Add to cart in place --------------------------------------------------------------------
document.addEventListener('submit', async (e) => {
    const form = e.target.closest('form[data-add-to-cart]');
    if (!form) return;
    e.preventDefault();
    const btn = form.querySelector('button[type=submit]');
    const label = btn?.innerHTML;
    if (btn) { btn.disabled = true; btn.setAttribute('aria-busy', 'true'); }
    try {
        const body = Object.fromEntries(new FormData(form));
        delete body._token;
        const data = await postJson(form.action, body);
        await flyToCart(form);
        setBadge(data.count);
        toast(data.message, { link: { href: '/shop/cart', label: 'View cart' } });
        if (btn) {
            btn.classList.add('is-done');
            btn.innerHTML = '✓ Added';
            setTimeout(() => { btn.classList.remove('is-done'); btn.innerHTML = label; }, 1800);
        }
    } catch (err) {
        toast(err.message, { tone: 'bad' });
    } finally {
        if (btn) { btn.disabled = false; btn.removeAttribute('aria-busy'); }
    }
});

// ---- Quantity steppers -----------------------------------------------------------------------
document.addEventListener('click', (e) => {
    const step = e.target.closest('[data-step]');
    if (!step) return;
    const input = step.closest('.s-qty')?.querySelector('input');
    if (!input) return;
    const min = Number(input.min || 0);
    const max = Number(input.max || 99);
    const next = Math.min(max, Math.max(min, Number(input.value || 0) + Number(step.dataset.step)));
    if (next === Number(input.value)) return;
    input.value = String(next);
    if (input.form?.hasAttribute('data-autosubmit')) input.form.requestSubmit();
});
document.addEventListener('change', (e) => {
    const input = e.target.closest('form[data-autosubmit] input[type=number]');
    if (input) input.form.requestSubmit();
});

// ---- Pickup branch from the browser's location (only after the customer agrees) ---------------
function locate(button, { quiet = false } = {}) {
    if (!('geolocation' in navigator)) {
        if (!quiet) toast('This browser can\'t share your location.', { tone: 'bad' });
        return;
    }
    if (button) { button.disabled = true; button.textContent = 'Finding your branch…'; }
    navigator.geolocation.getCurrentPosition(async (pos) => {
        try {
            const data = await postJson('/shop/branch', { latitude: pos.coords.latitude, longitude: pos.coords.longitude });
            if (data.note) sessionStorage.setItem('melai.shop.note', data.note);
            if (data.changed || !quiet) window.location.reload();
        } catch (err) {
            if (!quiet) toast(err.message, { tone: 'bad' });
            if (button) { button.disabled = false; button.textContent = 'Use my location'; }
        }
    }, () => {
        if (!quiet) toast('Location is off. Allow location for this site to find your nearest branch.', { tone: 'bad' });
        if (button) { button.disabled = false; button.textContent = 'Use my location'; }
    }, { enableHighAccuracy: false, timeout: 10000, maximumAge: 300000 });
}
document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-locate]');
    if (b) { e.preventDefault(); locate(b); }
});
// Already allowed before: refresh the branch quietly once per visit, like the app does when it opens.
(() => {
    if (!document.querySelector('[data-branch-auto]') || !navigator.permissions?.query) return;
    try {
        if (sessionStorage.getItem('melai.shop.located')) return;
        sessionStorage.setItem('melai.shop.located', '1');
    } catch { return; }
    navigator.permissions.query({ name: 'geolocation' }).then((p) => { if (p.state === 'granted') locate(null, { quiet: true }); }).catch(() => {});
})();
try {
    const note = sessionStorage.getItem('melai.shop.note');
    if (note) { sessionStorage.removeItem('melai.shop.note'); toast(note); }
} catch { /* storage blocked */ }

// ---- Password checklist (same rules as the app) ---------------------------------------------
document.querySelectorAll('[data-pw-rules]').forEach((list) => {
    const input = document.getElementById(list.dataset.pwRules);
    if (!input) return;
    const tests = {
        length: (v) => v.length >= 8 && v.length <= 64,
        upper: (v) => /[A-Z]/.test(v),
        digit: (v) => /[0-9]/.test(v),
        special: (v) => /[^A-Za-z0-9\s]/.test(v),
    };
    const update = () => list.querySelectorAll('[data-rule]').forEach((li) => li.classList.toggle('ok', tests[li.dataset.rule](input.value)));
    input.addEventListener('input', update);
    update();
});
document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-show-pw]');
    if (!b) return;
    const input = document.getElementById(b.dataset.showPw);
    const show = input.type === 'password';
    input.type = show ? 'text' : 'password';
    b.textContent = show ? 'Hide' : 'Show';
    b.setAttribute('aria-pressed', String(show));
});

// ---- Payment check after HitPay (only the HitPay webhook marks money paid) --------------------
const poll = document.querySelector('[data-poll-url]');
if (poll) {
    const started = Date.now();
    const initial = poll.dataset.pollStatus;
    const tick = async () => {
        try {
            const res = await fetch(poll.dataset.pollUrl, { headers: { Accept: 'application/json' }, credentials: 'same-origin' });
            if (res.ok) {
                const s = await res.json();
                const paid = s.payment_status === 'success' || s.downpayment_status === 'success' || (initial === 'awaitingDownpayment' && s.status !== 'awaitingDownpayment');
                if (paid || s.status !== initial) { window.location.href = window.location.pathname; return; }
            }
        } catch { /* keep trying */ }
        if (Date.now() - started < 180000) setTimeout(tick, 4000);
        else poll.textContent = 'We haven\'t received the payment confirmation yet. It can take a few minutes; refresh this page to check again.';
    };
    setTimeout(tick, 2500);
}

// ---- Motion helpers ----------------------------------------------------------------------------
const reduceMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/** A copy of the product picture flies into the cart icon, then the badge bumps. */
function flyToCart(form) {
    const target = document.querySelector('[data-cart-target]');
    const source = form.closest('.s-card, .s-product')?.querySelector('[data-fly-src]');
    if (!target || !source || reduceMotion() || !source.animate) return Promise.resolve();
    const from = source.getBoundingClientRect();
    const to = target.getBoundingClientRect();
    const size = Math.min(from.width, from.height, 140);
    const fly = document.createElement('div');
    fly.className = 's-fly';
    fly.setAttribute('aria-hidden', 'true');
    fly.innerHTML = (source.querySelector('img, svg')?.outerHTML) || '';
    Object.assign(fly.style, { width: size + 'px', height: size + 'px', left: (from.left + from.width / 2 - size / 2) + 'px', top: (from.top + from.height / 2 - size / 2) + 'px' });
    document.body.appendChild(fly);
    const dx = to.left + to.width / 2 - (from.left + from.width / 2);
    const dy = to.top + to.height / 2 - (from.top + from.height / 2);
    const anim = fly.animate([
        { transform: 'translate(0, 0) scale(1)', opacity: 1 },
        { transform: `translate(${dx * 0.55}px, ${dy * 0.55 - 70}px) scale(.55)`, opacity: 1, offset: 0.6 },
        { transform: `translate(${dx}px, ${dy}px) scale(.12)`, opacity: 0.4 },
    ], { duration: 700, easing: 'cubic-bezier(.5, 0, .2, 1)' });
    return anim.finished.catch(() => {}).then(() => fly.remove());
}

/** Scroll reveal: sections glide in once as they come into view (everything visible without JS). */
(() => {
    const items = document.querySelectorAll('[data-reveal]');
    if (!items.length) return;
    if (reduceMotion() || !('IntersectionObserver' in window)) { items.forEach((el) => el.classList.add('is-in')); return; }
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
        if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); }
    }), { rootMargin: '0px 0px -6% 0px', threshold: 0.08 });
    items.forEach((el) => io.observe(el));
    // Restored from the back/forward cache: never leave anything hidden.
    window.addEventListener('pageshow', (e) => { if (e.persisted) items.forEach((el) => el.classList.add('is-in')); });
})();

/** Product photos: a soft shimmer until the picture has loaded. */
document.querySelectorAll('img[data-skel-img]').forEach((img) => {
    const done = () => { img.classList.add('is-loaded'); img.closest('.s-skel')?.classList.remove('s-skel'); };
    if (img.complete && img.naturalWidth) done(); else { img.addEventListener('load', done, { once: true }); img.addEventListener('error', done, { once: true }); }
});

/** Light / dark: light by default; dark only when chosen here (saved in this browser). */
(() => {
    const buttons = document.querySelectorAll('[data-theme-set]');
    const sync = () => buttons.forEach((b) => b.setAttribute('aria-pressed', String((document.documentElement.dataset.theme || 'light') === b.dataset.themeSet)));
    buttons.forEach((b) => b.addEventListener('click', () => {
        const theme = b.dataset.themeSet === 'dark' ? 'dark' : 'light';
        document.documentElement.dataset.theme = theme;
        try { localStorage.setItem('melai.shop.theme', theme); } catch { /* storage blocked */ }
        sync();
    }));
    sync();
})();
