// Idempotency key of the website's "New order" (in-store sale), kept apart from ui.js so it can be
// tested with plain Node (`npm run test:js`, tests/js/sale-key.test.js). No DOM, no imports.
//
// The database (staff_create_pos_sale, migration 20261027000000) returns the recorded sale for the
// same key + same details, and REFUSES the same key with different details. So:
//   * a changed sale (lines, branch, method, cash, reference) gets a new key, so the corrected sale
//     goes through;
//   * EXCEPT after a request whose outcome is unknown (network error, timeout, 5xx): the sale may
//     already be recorded, and only the same key lets the database say so instead of recording a
//     second one. That stays so until a new sale is started;
//   * a finished sale's key is never used again.

export const newSaleKey = () => (globalThis.crypto?.randomUUID?.() || String(Date.now()) + Math.random());

/** True when a failed request may still have been recorded (it never got a clear answer). */
export const outcomeUnknown = (e) => !e?.status || e.status === 408 || e.status >= 500;

/** The sale changed: new key, unless an earlier request's outcome is unknown. Returns the key. */
export function rotateSaleKey(state, makeKey = newSaleKey) {
    if (state.outcomeUnknown) return state.key;
    state.key = makeKey();
    return state.key;
}

/** A request failed: remember when its outcome is unknown (the key is then kept). */
export function noteFailedSale(state, error) {
    if (outcomeUnknown(error)) state.outcomeUnknown = true;
}

/** A new sale (modal opened, or the last sale was recorded): fresh key, nothing unknown. */
export function startNewSale(state, makeKey = newSaleKey) {
    state.outcomeUnknown = false;
    state.key = makeKey();
    return state.key;
}
