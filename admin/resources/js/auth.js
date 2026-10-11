import Alpine from 'alpinejs';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

// Client-side validation for login + register. The server (Form Requests) is still the real gatekeeper.
Alpine.data('authForm', (opts = {}) => ({
    mode: opts.mode ?? 'login',
    values: { name: opts.old?.name ?? '', email: opts.old?.email ?? '', password: '', password_confirmation: '' },
    serverErrors: Object.fromEntries(Object.entries(opts.errors ?? {}).map(([k, v]) => [k, Array.isArray(v) ? v[0] : v])),
    touched: {}, edited: {}, submitting: false,
    show: { password: false, password_confirmation: false },

    init() {
        window.addEventListener('pageshow', () => { this.submitting = false; }); // back button
    },

    touch(f) { this.touched[f] = true; },
    edit(f) { this.edited[f] = true; this.touched[f] = true; },

    error(f) {
        if (this.serverErrors[f] && !this.edited[f]) return this.serverErrors[f];
        return this.touched[f] ? this.validate(f) : '';
    },

    get ruleList() {
        const p = this.values.password;
        return [
            { label: '8+ characters', msg: 'Use at least 8 characters.', ok: p.length >= 8 },
            { label: 'Uppercase', msg: 'Add an uppercase letter.', ok: /\p{Lu}/u.test(p) },
            { label: 'Lowercase', msg: 'Add a lowercase letter.', ok: /\p{Ll}/u.test(p) },
            { label: 'Number', msg: 'Add a number.', ok: /\d/.test(p) },
            { label: 'Symbol', msg: 'Add a symbol, e.g. ! @ # $.', ok: /[\p{P}\p{S}]/u.test(p) },
        ];
    },

    get strength() {
        const score = this.ruleList.filter(r => r.ok).length + (this.values.password.length >= 12 ? 1 : 0);
        const [label, cls] = score <= 2 ? ['Weak', 'weak'] : score <= 4 ? ['Fair', 'fair'] : score === 5 ? ['Good', 'good'] : ['Strong', 'strong'];
        return { label, cls, pct: Math.round((score / 6) * 100) };
    },

    validate(f) {
        const v = this.values[f] ?? '';
        if (f === 'name') {
            const t = v.trim();
            return !t ? 'Full name is required.' : t.length < 2 ? 'Name must be at least 2 characters.' : t.length > 100 ? 'Name must be 100 characters or less.' : '';
        }
        if (f === 'email') {
            const t = v.trim();
            return !t ? 'Email is required.' : t.length > 255 ? 'Email must be 255 characters or less.' : !EMAIL_RE.test(t) ? 'Enter a valid email address.' : '';
        }
        if (f === 'password') {
            if (!v) return 'Password is required.';
            return this.mode === 'login' ? '' : (this.ruleList.find(r => !r.ok)?.msg ?? '');
        }
        if (f === 'password_confirmation' && this.mode === 'register') {
            return !v ? 'Please confirm your password.' : v !== this.values.password ? 'Passwords do not match.' : '';
        }
        return '';
    },

    onSubmit(e) {
        if (this.submitting) return e.preventDefault();
        const fields = this.mode === 'register' ? ['name', 'email', 'password', 'password_confirmation'] : ['email', 'password'];
        fields.forEach(f => { this.touched[f] = true; this.edited[f] = true; });
        if (fields.some(f => this.validate(f))) {
            e.preventDefault();
            this.$nextTick(() => this.$el.querySelector('.is-invalid')?.focus());
            return;
        }
        this.submitting = true; // disables the button while the request is sent
    },
}));
