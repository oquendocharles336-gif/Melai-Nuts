'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { deactivateAccount, reactivateAccount } = require('../lib/account-status');

// Minimal in-memory fakes that record every call in order.
function fakes({ users = {}, authUsers = ['u1', 'owner1', 'owner2'], failOn = {} } = {}) {
  const calls = [];
  const maybeFail = (name) => { if (failOn[name]) throw new Error(`${name} failed`); };
  const auth = {
    async getUser(uid) { calls.push(['getUser', uid]); if (!authUsers.includes(uid)) { const e = new Error('no such user'); e.code = 'auth/user-not-found'; throw e; } },
    async updateUser(uid, patch) { maybeFail('updateUser'); calls.push(['updateUser', uid, patch]); },
    async revokeRefreshTokens(uid) { maybeFail('revokeRefreshTokens'); calls.push(['revokeRefreshTokens', uid]); },
  };
  const firestore = {
    collection(name) {
      assert.equal(name, 'users');
      return {
        doc: (uid) => ({
          async get() { calls.push(['profile.get', uid]); return { exists: uid in users, data: () => users[uid] }; },
          async update(patch) { maybeFail('profile.update'); calls.push(['profile.update', uid, patch]); Object.assign(users[uid], patch); },
        }),
        where(field, op, value) {
          const filters = [[field, op, value]];
          const q = {
            where(f, o, v) { filters.push([f, o, v]); return q; },
            limit() { return q; },
            async get() {
              const docs = Object.entries(users).filter(([, d]) => filters.every(([f, , v]) => d[f] === v)).map(([id, d]) => ({ id, data: () => d }));
              return { docs: docs.slice(0, 2) };
            },
          };
          return q;
        },
      };
    },
  };
  return { deps: { auth, firestore }, calls, users };
}
const names = (calls) => calls.map((c) => c[0]);

test('deactivate: disables sign-in, revokes sessions, then flags the profile, in that order', async () => {
  const { deps, calls, users } = fakes({ users: { u1: { role: 'customer', isActive: true } } });
  const steps = await deactivateAccount(deps, 'u1');
  assert.deepEqual(steps, ['auth-disabled', 'sessions-revoked', 'profile-flagged-inactive']);
  assert.deepEqual(names(calls), ['getUser', 'profile.get', 'updateUser', 'revokeRefreshTokens', 'profile.update']);
  assert.deepEqual(calls.find((c) => c[0] === 'updateUser')[2], { disabled: true });
  assert.equal(users.u1.isActive, false);
});

test('deactivate: an unknown uid fails before anything is touched', async () => {
  const { deps, calls } = fakes({ users: {} });
  await assert.rejects(deactivateAccount(deps, 'ghost'), (e) => e.code === 'auth/user-not-found' && Array.isArray(e.completedSteps) && e.completedSteps.length === 0);
  assert.deepEqual(names(calls), ['getUser']);
});

test('deactivate: an account with no profile is still locked out', async () => {
  const { deps, calls } = fakes({ users: {} });
  const steps = await deactivateAccount(deps, 'u1');
  assert.deepEqual(steps, ['auth-disabled', 'sessions-revoked', 'no-profile-to-flag']);
  assert.ok(!names(calls).includes('profile.update'));
});

test('deactivate: running it twice is harmless', async () => {
  const { deps, users } = fakes({ users: { u1: { role: 'customer', isActive: true } } });
  await deactivateAccount(deps, 'u1');
  await deactivateAccount(deps, 'u1');
  assert.equal(users.u1.isActive, false);
});

test('deactivate: a failure part-way reports exactly what was already done (and access is already cut)', async () => {
  const { deps, calls, users } = fakes({ users: { u1: { role: 'customer', isActive: true } }, failOn: { revokeRefreshTokens: true } });
  await assert.rejects(deactivateAccount(deps, 'u1'), (e) => {
    assert.deepEqual(e.completedSteps, ['auth-disabled']);
    return /revokeRefreshTokens failed/.test(e.message);
  });
  assert.equal(users.u1.isActive, true, 'profile not touched yet');
  assert.ok(calls.some((c) => c[0] === 'updateUser'), 'sign-in was already disabled');
});

test('deactivate: an owner needs --allow-owner, and nothing is changed without it', async () => {
  const { deps, calls } = fakes({ users: { owner1: { role: 'owner', isActive: true }, owner2: { role: 'owner', isActive: true } } });
  await assert.rejects(deactivateAccount(deps, 'owner1'), /--allow-owner/);
  assert.ok(!names(calls).includes('updateUser'));
});

test('deactivate: the LAST active owner can never be deactivated, even with --allow-owner', async () => {
  const { deps, calls, users } = fakes({ users: { owner1: { role: 'owner', isActive: true } } });
  await assert.rejects(deactivateAccount(deps, 'owner1', { allowOwner: true }), /last active owner/);
  assert.ok(!names(calls).includes('updateUser'));
  assert.equal(users.owner1.isActive, true);
});

test('deactivate: an owner can be deactivated when another active owner exists', async () => {
  const { deps, users } = fakes({ users: { owner1: { role: 'owner', isActive: true }, owner2: { role: 'owner', isActive: true } } });
  await deactivateAccount(deps, 'owner1', { allowOwner: true });
  assert.equal(users.owner1.isActive, false);
  assert.equal(users.owner2.isActive, true);
});

test('deactivate: re-running on an owner who is already inactive is allowed (cleanup after a partial run)', async () => {
  const { deps } = fakes({ users: { owner1: { role: 'owner', isActive: false }, owner2: { role: 'owner', isActive: true } } });
  assert.deepEqual(await deactivateAccount(deps, 'owner1', { allowOwner: true }), ['auth-disabled', 'sessions-revoked', 'profile-flagged-inactive']);
});

test('reactivate: flags the profile active first, then enables sign-in', async () => {
  const { deps, calls, users } = fakes({ users: { u1: { role: 'customer', isActive: false } } });
  const steps = await reactivateAccount(deps, 'u1');
  assert.deepEqual(steps, ['profile-flagged-active', 'auth-enabled']);
  assert.deepEqual(names(calls), ['getUser', 'profile.get', 'profile.update', 'updateUser']);
  assert.deepEqual(calls.find((c) => c[0] === 'updateUser')[2], { disabled: false });
  assert.equal(users.u1.isActive, true);
});

test('reactivate: a failure part-way reports what was done', async () => {
  const { deps } = fakes({ users: { u1: { role: 'customer', isActive: false } }, failOn: { updateUser: true } });
  await assert.rejects(reactivateAccount(deps, 'u1'), (e) => { assert.deepEqual(e.completedSteps, ['profile-flagged-active']); return true; });
});

test('reactivate: unknown uid fails before anything is touched', async () => {
  const { deps, calls } = fakes({ users: {} });
  await assert.rejects(reactivateAccount(deps, 'ghost'), (e) => e.code === 'auth/user-not-found');
  assert.deepEqual(names(calls), ['getUser']);
});
