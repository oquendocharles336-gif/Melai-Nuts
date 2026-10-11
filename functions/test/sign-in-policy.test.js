'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { decideSignIn } = require('../lib/sign-in-policy');

const quiet = () => { const calls = []; return { calls, error: (...a) => calls.push(a), warn() {}, info() {} }; };
const returns = (profile) => async () => profile;

test('a brand-new account with no profile yet may sign in (registration needs this)', async () => {
  assert.deepEqual(await decideSignIn('u1', returns(null)), { allow: true, reason: 'no-profile' });
  assert.deepEqual(await decideSignIn('u1', returns(undefined)), { allow: true, reason: 'no-profile' });
});

test('an active profile may sign in, with or without the isActive field', async () => {
  assert.equal((await decideSignIn('u1', returns({ role: 'customer', isActive: true }))).allow, true);
  assert.equal((await decideSignIn('u1', returns({ role: 'customer' }))).allow, true, 'absent isActive counts as active, like firestore.rules');
});

test('isActive anything other than true is refused (matches firestore.rules activeUser())', async () => {
  for (const value of [false, null, 'false', 'true', 0, 1, [], {}]) {
    const d = await decideSignIn('u1', returns({ role: 'staff', isActive: value }));
    assert.deepEqual(d, { allow: false, reason: 'deactivated' }, `isActive=${JSON.stringify(value)}`);
  }
});

test('the profile is read for exactly the signing-in uid', async () => {
  const seen = [];
  await decideSignIn('abc123', async (uid) => { seen.push(uid); return null; });
  assert.deepEqual(seen, ['abc123']);
});

test('a missing or malformed uid is refused without reading anything', async () => {
  let reads = 0;
  const read = async () => { reads++; return null; };
  for (const uid of [undefined, null, '', 42, {}]) {
    assert.deepEqual(await decideSignIn(uid, read), { allow: false, reason: 'missing-uid' });
  }
  assert.equal(reads, 0);
});

test('a read failure allows sign-in by default and is logged', async () => {
  const log = quiet();
  const d = await decideSignIn('u1', async () => { throw new Error('firestore down'); }, { log });
  assert.deepEqual(d, { allow: true, reason: 'profile-unavailable-allowed' });
  assert.equal(log.calls.length, 1);
  assert.match(JSON.stringify(log.calls[0]), /firestore down/);
});

test('a synchronous throw from the reader is handled the same way', async () => {
  const d = await decideSignIn('u1', () => { throw new Error('boom'); }, { log: quiet() });
  assert.equal(d.reason, 'profile-unavailable-allowed');
});

test('failClosed refuses sign-in when the profile cannot be read', async () => {
  const d = await decideSignIn('u1', async () => { throw new Error('down'); }, { failClosed: true, log: quiet() });
  assert.deepEqual(d, { allow: false, reason: 'profile-unavailable' });
});

test('a hung read times out (blocking functions have a hard 7 s limit)', async () => {
  const never = () => new Promise(() => {});
  const started = Date.now();
  const open = await decideSignIn('u1', never, { timeoutMs: 25, log: quiet() });
  assert.equal(open.reason, 'profile-unavailable-allowed');
  assert.ok(Date.now() - started < 1000, 'returned promptly');
  const closed = await decideSignIn('u1', never, { timeoutMs: 25, failClosed: true, log: quiet() });
  assert.equal(closed.reason, 'profile-unavailable');
});

test('a fast read is not affected by the timeout', async () => {
  const d = await decideSignIn('u1', returns({ isActive: false }), { timeoutMs: 1000 });
  assert.equal(d.allow, false);
});
