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
    if (res.status === 401 && data.signed_out) window.location.href = '/?panel=sign-in';
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

// ---- Live field validation (forms marked data-live-validate) -----------------------------------
// A field stays neutral until the person leaves it once; after that it re-validates as they type:
// red (.has-err + message in .err) when wrong, green (.is-valid) when right. Same rules and
// messages as admin/app/Http/Requests/Rules.php and the app's ValidationUtils. The server still
// validates everything; this only gives earlier feedback.
(() => {
    const LIMITS = { name: 50, email: 254, pwMin: 8, pwMax: 64 };
    const NAME_RE = /^[\p{L}\p{M}\s'’.\-]+$/u;
    const PH_MOBILE_RE = /^(?:\+63|63|0)?9\d{9}$/;
    const EMAIL_LOCAL_RE = /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$/;
    const EMAIL_LABEL_RE = /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
    const EMAIL_TLD_RE = /^[A-Za-z]{2,24}$/;
    const WEAK_WORDS = new Set([
        'password', 'passw', 'pass', 'pword', 'qwerty', 'qwertyuiop', 'asdf', 'asdfgh',
        'zxcvbn', 'welcome', 'admin', 'administrator', 'letmein', 'iloveyou', 'abc',
        'abcd', 'abcdef', 'abcdefg', 'monkey', 'dragon', 'football', 'baseball',
        'sunshine', 'princess', 'master', 'login', 'changeme', 'secret', 'melainuts',
        'melai', 'nuts', 'test', 'user', 'qazwsx', 'trustno', 'iloveu', 'mahalkita',
    ]);

    const isCommonPassword = (password) => {
        const lower = password.toLowerCase();
        const letters = (v) => v.replace(/[^a-z]/g, '');
        if (letters(lower) === '') return true;
        const leet = lower.replace(/@/g, 'a').replace(/0/g, 'o').replace(/3/g, 'e').replace(/\$/g, 's');
        return [letters(lower), letters(leet), letters(leet.replace(/1/g, 'i')), letters(leet.replace(/1/g, 'l'))].some((c) => WEAK_WORDS.has(c));
    };

    // Each rule returns an error message, or null when the value is fine. `ctx` reads the other
    // fields of the same form (the password checks look at the email and name).
    const rules = {
        name(v) {
            const t = v.trim();
            if (t === '') return 'Full name is required.';
            if (t.length < 2) return 'Name must be at least 2 characters long.';
            if (t.length > LIMITS.name) return `Name cannot exceed ${LIMITS.name} characters.`;
            if (!NAME_RE.test(t)) return 'Name should only contain letters, spaces, hyphens, apostrophes or periods.';
            if ((t.match(/\p{L}/gu) || []).length < 2) return 'Please enter a valid name.';
            return null;
        },
        email(v) {
            const t = v.trim();
            if (t === '') return 'Email is required.';
            const invalid = 'Please enter a valid email address (e.g. user@example.com).';
            if (t.length > LIMITS.email) return invalid;
            const at = t.indexOf('@');
            if (at <= 0 || at !== t.lastIndexOf('@')) return invalid;
            const local = t.slice(0, at);
            const labels = t.slice(at + 1).split('.');
            if (local.length > 64 || !EMAIL_LOCAL_RE.test(local)) return invalid;
            if (labels.length < 2 || !labels.every((l) => EMAIL_LABEL_RE.test(l)) || !EMAIL_TLD_RE.test(labels[labels.length - 1])) return invalid;
            return null;
        },
        phone(v) {
            const t = v.trim();
            if (t === '') return 'Mobile number is required.';
            return PH_MOBILE_RE.test(t.replace(/[\s\-().]/g, '')) ? null : 'Please enter a valid Philippine mobile number, e.g. 0917 123 4567.';
        },
        password(v, ctx) {
            if (v === '') return 'Password is required.';
            if (v.trim() === '') return 'Password cannot be only spaces.';
            if (v.length < LIMITS.pwMin) return `Password must be at least ${LIMITS.pwMin} characters long.`;
            if (v.length > LIMITS.pwMax) return `Password cannot exceed ${LIMITS.pwMax} characters.`;
            if (!/\p{Lu}/u.test(v)) return 'Password must contain at least one uppercase letter (A-Z).';
            if (!/\p{Ll}/u.test(v)) return 'Password must contain at least one lowercase letter (a-z).';
            if (!/\p{N}/u.test(v)) return 'Password must contain at least one number (0-9).';
            if (!/[\p{Z}\p{S}\p{P}]/u.test(v)) return 'Password must contain at least one special character (!@#$...).';
            const lower = v.toLowerCase();
            const local = (ctx.value('email') || '').trim().toLowerCase().split('@')[0];
            if (local.length >= 3 && lower.includes(local)) return 'Password must not contain your email address.';
            for (const part of (ctx.value('name') || '').toLowerCase().split(/[\s\-.]+/)) {
                if (part.length >= 3 && lower.includes(part)) return 'Password must not contain your name.';
            }
            if (isCommonPassword(v)) return 'This password is too common. Choose something harder to guess.';
            return null;
        },
        confirm(v, ctx) {
            if (v === '') return 'Please confirm your password.';
            return v === ctx.value('password') ? null : 'Passwords do not match.';
        },
        terms(_v, _ctx, el) {
            return el.checked ? null : 'Please agree to the Terms and Conditions and the Privacy Policy.';
        },
    };
    // Which rule a field uses comes from its name attribute.
    const ruleFor = { name: 'name', email: 'email', phone: 'phone', password: 'password', password_confirmation: 'confirm', terms: 'terms' };
    // Fields whose result depends on another one, so they re-check when it changes.
    const dependents = { password: ['confirm'], email: ['password'], name: ['password'] };

    const state = new WeakMap();   // field -> { touched, serverValue }
    const formOf = (el) => el.closest('form[data-live-validate]');
    const ruleOf = (el) => (el.matches('input') ? ruleFor[el.name] : null);
    const fieldByRule = (form, rule) => [...form.querySelectorAll('input[name]')].find((i) => ruleOf(i) === rule);
    const wrapOf = (el) => (el.type === 'checkbox' ? el.closest('label.s-check') : el.closest('.s-field'));

    /** The message element: the server-rendered one when there is one, otherwise a new one. */
    const messageEl = (el) => {
        const wrap = wrapOf(el);
        let msg = el.type === 'checkbox'
            ? (wrap.nextElementSibling?.classList.contains('s-err') ? wrap.nextElementSibling : null)
            : wrap.querySelector('.err');
        if (!msg) {
            msg = document.createElement('span');
            msg.className = el.type === 'checkbox' ? 's-err' : 'err';
            msg.hidden = true;
            if (el.type === 'checkbox') wrap.after(msg); else wrap.appendChild(msg);
        }
        if (!msg.id) msg.id = `${el.id || el.name}-err`;
        msg.setAttribute('role', 'alert');
        return msg;
    };

    const paint = (el, error, showValid) => {
        const wrap = wrapOf(el);
        const msg = messageEl(el);
        wrap.classList.toggle('has-err', !!error);
        wrap.classList.toggle('is-valid', !error && showValid);
        msg.textContent = error || '';
        msg.hidden = !error;
        const ids = new Set((el.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean));
        if (error) { ids.add(msg.id); el.setAttribute('aria-invalid', 'true'); } else { ids.delete(msg.id); el.removeAttribute('aria-invalid'); }
        if (ids.size) el.setAttribute('aria-describedby', [...ids].join(' ')); else el.removeAttribute('aria-describedby');
    };

    /** Validates one field and paints it. Returns the error message, or null. */
    const check = (el) => {
        const form = formOf(el);
        const rule = ruleOf(el);
        if (!form || !rule) return null;
        const ctx = { value: (r) => fieldByRule(form, r)?.value ?? '' };
        // Optional (no `required`) and empty: nothing to say. Consent is always required.
        if (rule !== 'terms' && !el.required && el.value === '') { paint(el, null, false); return null; }
        const error = rules[rule](el.value, ctx, el);
        paint(el, error, true);
        return error;
    };

    const st = (el) => { if (!state.has(el)) state.set(el, { touched: false, serverValue: null }); return state.get(el); };
    const run = (el) => {
        const s = st(el);
        s.touched = true;
        // A server message (e.g. "account already exists") stays until the value is changed.
        if (s.serverValue !== null && el.value === s.serverValue && el.type !== 'checkbox') return null;
        return check(el);
    };
    const rerunDependents = (el) => {
        const form = formOf(el);
        (dependents[ruleOf(el)] || []).forEach((rule) => {
            const other = form && fieldByRule(form, rule);
            if (other && st(other).touched) { st(other).serverValue = null; check(other); }
        });
    };

    // Errors the server rendered stay red on load; those fields count as already touched.
    document.querySelectorAll('form[data-live-validate] input[name]').forEach((el) => {
        if (!ruleOf(el)) return;
        const s = st(el);
        if (wrapOf(el)?.classList.contains('has-err')) { s.touched = true; s.serverValue = el.value; messageEl(el); }
    });

    // Leaving a field (checkboxes check on change: ticking is the whole interaction).
    document.addEventListener('focusout', (e) => {
        const el = e.target;
        if (!(el instanceof HTMLInputElement) || !formOf(el) || !ruleOf(el) || el.type === 'checkbox') return;
        run(el);
        rerunDependents(el);
    });
    // After the first blur: live, so red turns green as soon as it is fixed (and back).
    document.addEventListener('input', (e) => {
        const el = e.target;
        if (!(el instanceof HTMLInputElement) || !formOf(el) || !ruleOf(el) || el.type === 'checkbox') return;
        if (!st(el).touched) return;
        st(el).serverValue = null;
        check(el);
        rerunDependents(el);
    });
    document.addEventListener('change', (e) => {
        const el = e.target;
        if (!(el instanceof HTMLInputElement) || el.type !== 'checkbox' || !formOf(el) || !ruleOf(el)) return;
        st(el).serverValue = null;
        run(el);
    });
    // Submit: check everything at once, mark every bad field, focus the first, send nothing.
    // Capture phase, so it runs before the "busy" button handler below.
    document.addEventListener('submit', (e) => {
        const form = e.target.closest?.('form[data-live-validate]');
        if (!form) return;
        let first = null;
        form.querySelectorAll('input[name]').forEach((el) => {
            if (!ruleOf(el)) return;
            st(el).serverValue = null;
            if (run(el) && !first) first = el;
        });
        if (first) { e.preventDefault(); e.stopImmediatePropagation(); first.focus(); }
    }, true);
})();

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

/**
 * Sign-in panel: the only sign-in. "Sign in" opens it on top of the homepage without leaving the
 * page, the links inside switch panels in place, and the address follows (/?panel=...) so Back and
 * sharing work. Without JavaScript the same links reload the homepage with that panel open.
 */
(() => {
    const dlg = document.querySelector('[data-auth-panel]');
    if (!dlg || typeof dlg.showModal !== 'function') return;
    const fine = window.matchMedia('(pointer: fine)').matches;   // no surprise keyboard on phones

    const setUrl = (name) => {
        try {
            const u = new URL(window.location.href);
            if (name) u.searchParams.set('panel', name); else u.searchParams.delete('panel');
            history.replaceState(history.state, '', u);
        } catch { /* old browser */ }
    };
    const show = (name) => {
        const sections = [...dlg.querySelectorAll('[data-panel]')];
        const target = sections.find((s) => s.dataset.panel === name) || sections.find((s) => s.dataset.panel === 'sign-in');
        sections.forEach((s) => { s.hidden = s !== target; });
        dlg.dataset.shown = target.dataset.panel;
        dlg.setAttribute('aria-labelledby', `ap-${target.dataset.panel}-title`);
        return target;
    };
    const focusIn = (section, always = false) => {
        if (!fine && !always) return;
        const input = section.querySelector('.has-err input, .has-err textarea') || section.querySelector('input:not([type=hidden]):not([type=checkbox])');
        input?.focus({ preventScroll: true });
    };
    const open = (name) => {
        const section = show(name);
        if (!dlg.open) dlg.showModal();
        dlg.scrollTop = 0;
        setUrl(dlg.dataset.shown);
        focusIn(section);
    };

    // Opened by the server (/?panel=..., or after a failed submit): make it a real modal
    // (focus stays inside, Esc closes) and put the cursor on the first field with an error.
    if (dlg.hasAttribute('data-start-open')) {
        dlg.removeAttribute('open');   // not close(): that would fire "close" and drop ?panel= from the address
        dlg.showModal();
        const section = dlg.querySelector('[data-panel]:not([hidden])');
        focusIn(section, !!section.querySelector('.has-err'));
    }

    dlg.addEventListener('close', () => setUrl(null));
    document.addEventListener('click', (e) => {
        const opener = e.target.closest('[data-panel-open]');
        if (opener) { e.preventDefault(); open(opener.dataset.panelOpen); return; }
        if (e.target.closest('[data-panel-close]')) { e.preventDefault(); dlg.close(); }
    });
    // A click on the dimmed area closes it (only when the press also started there, so selecting
    // text in a field and letting go outside never closes the panel).
    let downOnBackdrop = false;
    dlg.addEventListener('pointerdown', (e) => { downOnBackdrop = e.target === dlg; });
    dlg.addEventListener('click', (e) => { if (downOnBackdrop && e.target === dlg) dlg.close(); downOnBackdrop = false; });
})();

/** Forms that take a moment (sign-in, sign-up): say so on the button and stop double sends. */
document.addEventListener('submit', (e) => {
    const form = e.target.closest('form[data-busy]');
    if (!form || e.defaultPrevented) return;
    const btn = form.querySelector('button[type=submit]');
    if (!btn) return;
    if (btn.getAttribute('aria-busy') === 'true') { e.preventDefault(); return; }
    btn.setAttribute('aria-busy', 'true');
    btn.dataset.label = btn.textContent;
    btn.textContent = form.dataset.busy;
});
window.addEventListener('pageshow', (e) => {
    if (!e.persisted) return;   // back from the next page: the buttons work again
    document.querySelectorAll('form[data-busy] button[aria-busy="true"]').forEach((b) => { b.removeAttribute('aria-busy'); if (b.dataset.label) b.textContent = b.dataset.label; });
});
