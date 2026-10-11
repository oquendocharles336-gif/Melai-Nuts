'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/identity');
const { makeSignInHandler, CLAIMS, DEACTIVATED_MARKER } = require('../lib/handlers');

const log = () => { const entries = { error: [], warn: [] }; return { entries, error: (...a) => entries.error.push(a), warn: (...a) => entries.warn.push(a), info() {} }; };
const event = (uid) => ({ data: { uid } });
const handlerFor = (profile, opts = {}) => makeSignInHandler({ readProfile: async () => profile, log: log(), ...opts });

test('the claim is ONLY the Postgres role, never an app role', () => {
  assert.deepEqual(CLAIMS, { role: 'authenticated' });
});

test('an active user gets the Supabase role claim', async () => {
  assert.deepEqual(await handlerFor({ role: 'customer', isActive: true })(event('u1')), { customClaims: { role: 'authenticated' } });
});

test('a user with no profile yet gets the claim (first sign-in during registration)', async () => {
  assert.deepEqual(await handlerFor(null)(event('new')), { customClaims: { role: 'authenticated' } });
});

test('a deactivated user is refused with permission-denied and the marker the app looks for', async () => {
  await assert.rejects(handlerFor({ role: 'staff', isActive: false })(event('u1')), (err) => {
    assert.ok(err instanceof HttpsError);
    assert.equal(err.code, 'permission-denied');
    assert.ok(err.message.includes(DEACTIVATED_MARKER));
    assert.match(err.message, /deactivated/i);
    return true;
  });
});

test('the refusal is logged with the uid and reason, not the profile contents', async () => {
  const l = log();
  const h = makeSignInHandler({ readProfile: async () => ({ isActive: false, email: 'secret@x.com' }), log: l });
  await assert.rejects(h(event('u9')));
  assert.equal(l.entries.warn.length, 1);
  const logged = JSON.stringify(l.entries.warn[0]);
  assert.match(logged, /u9/);
  assert.match(logged, /deactivated/);
  assert.doesNotMatch(logged, /secret@x\.com/);
});

test('a profile read failure still lets the user in by default', async () => {
  const h = makeSignInHandler({ readProfile: async () => { throw new Error('down'); }, log: log() });
  assert.deepEqual(await h(event('u1')), { customClaims: { role: 'authenticated' } });
});

test('failClosed turns a read failure into a refusal', async () => {
  const h = makeSignInHandler({ readProfile: async () => { throw new Error('down'); }, log: log(), failClosed: true });
  await assert.rejects(h(event('u1')), (err) => err.code === 'permission-denied');
});

test('a malformed event is refused rather than crashing or allowing', async () => {
  const h = handlerFor(null);
  for (const bad of [undefined, null, {}, { data: {} }, { data: { uid: '' } }]) {
    await assert.rejects(h(bad), (err) => err instanceof HttpsError && err.code === 'permission-denied');
  }
});
