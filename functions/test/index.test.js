'use strict';
// Loads the REAL index.js with only the Firebase Admin SDK and the trigger
// registration stubbed, to prove the wiring: what is exported, that the
// sign-in handler really reads users/{uid}, and that the Admin SDK is
// initialised lazily and once.
const { test, before } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');

const realIdentity = require('firebase-functions/v2/identity');
const state = { apps: [], inits: 0, reads: [], profiles: {}, failRead: false };

const stubs = {
  'firebase-admin/app': { initializeApp: () => { state.inits++; state.apps.push({}); }, getApps: () => state.apps },
  'firebase-admin/firestore': {
    getFirestore: () => ({
      collection: (name) => ({
        doc: (id) => ({
          get: async () => {
            state.reads.push(`${name}/${id}`);
            if (state.failRead) throw new Error('firestore unavailable');
            const data = state.profiles[id];
            return { exists: data !== undefined, data: () => data };
          },
        }),
      }),
    }),
  },
  'firebase-functions/v2/identity': {
    ...realIdentity,
    beforeUserCreated: (handler) => ({ trigger: 'beforeUserCreated', handler }),
    beforeUserSignedIn: (handler) => ({ trigger: 'beforeUserSignedIn', handler }),
  },
};

let index;
before(() => {
  const originalLoad = Module._load;
  Module._load = function patched(request, parent, isMain) {
    if (Object.prototype.hasOwnProperty.call(stubs, request)) return stubs[request];
    return originalLoad.call(this, request, parent, isMain);
  };
  try {
    for (const key of Object.keys(require.cache)) {
      if (key.startsWith(path.resolve(__dirname, '..') + path.sep) && !key.includes('node_modules')) delete require.cache[key];
    }
    index = require('../index.js');
  } finally {
    Module._load = originalLoad;
  }
});

const quietly = async (fn) => {
  const orig = [console.error, console.warn, console.log, console.info];
  console.error = console.warn = console.log = console.info = () => {};
  try { return await fn(); } finally { [console.error, console.warn, console.log, console.info] = orig; }
};

test('index.js exports exactly the two blocking functions (no accidental extra deploy surface)', () => {
  assert.deepEqual(Object.keys(index).sort(), ['supabaseRoleOnCreate', 'supabaseRoleOnSignIn']);
  assert.equal(index.supabaseRoleOnCreate.trigger, 'beforeUserCreated');
  assert.equal(index.supabaseRoleOnSignIn.trigger, 'beforeUserSignedIn');
});

test('sign-up still stamps the Supabase role claim', () => {
  assert.deepEqual(index.supabaseRoleOnCreate.handler(), { customClaims: { role: 'authenticated' } });
});

test('Admin SDK is not initialised at load time', () => {
  assert.equal(state.inits, 0);
});

test('sign-in for an active user reads users/{uid} and returns the claim', async () => {
  state.profiles = { u1: { role: 'customer', isActive: true } };
  const out = await quietly(() => index.supabaseRoleOnSignIn.handler({ data: { uid: 'u1' } }));
  assert.deepEqual(out, { customClaims: { role: 'authenticated' } });
  assert.deepEqual(state.reads.slice(-1), ['users/u1']);
});

test('sign-in for a deactivated user is refused', async () => {
  state.profiles = { u2: { role: 'staff', isActive: false } };
  await quietly(async () => {
    await assert.rejects(index.supabaseRoleOnSignIn.handler({ data: { uid: 'u2' } }), (e) => e.code === 'permission-denied' && /ACCOUNT_DEACTIVATED/.test(e.message));
  });
});

test('sign-in for a user with no profile yet is allowed', async () => {
  state.profiles = {};
  const out = await quietly(() => index.supabaseRoleOnSignIn.handler({ data: { uid: 'fresh' } }));
  assert.deepEqual(out, { customClaims: { role: 'authenticated' } });
});

test('a Firestore outage does not lock users out', async () => {
  state.failRead = true;
  try {
    const out = await quietly(() => index.supabaseRoleOnSignIn.handler({ data: { uid: 'u1' } }));
    assert.deepEqual(out, { customClaims: { role: 'authenticated' } });
  } finally { state.failRead = false; }
});

test('the Admin SDK was initialised once, lazily, on first use', () => {
  assert.equal(state.inits, 1);
});
