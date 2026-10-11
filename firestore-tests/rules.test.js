// Firestore rules tests. Run:  cd firestore-tests && npm install && npm test
// (needs Java; downloads the Firestore emulator on first run).
// NOTE: written alongside the rules but NOT executed in the authoring sandbox
// (the emulator download is blocked there: storage.googleapis.com is not on the
// network allowlist) — run them before deploying.
//
// The app uses exactly ONE Firestore collection (`users`). Every other
// collection is denied to everyone, including owners; the matrix below pins
// that down so a collection cannot be re-opened by accident.
const { initializeTestEnvironment, assertFails, assertSucceeds } = require('@firebase/rules-unit-testing');
const { doc, collection, getDoc, getDocs, setDoc, updateDoc, deleteDoc, serverTimestamp } = require('firebase/firestore');
const { readFileSync } = require('node:fs');
const { test, before, after, beforeEach } = require('node:test');

let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-melai',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(() => env.cleanup());

const profile = (role, extra = {}) => ({
  email: `${role}@x.com`, name: role, role, phone: null, branch: null,
  isActive: true, createdAt: new Date(), ...extra,
});
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users/owner1'), profile('owner'));
    await setDoc(doc(db, 'users/staffA'), profile('staff', { branch: 'Calamba Branch' }));
    await setDoc(doc(db, 'users/staffOff'), profile('staff', { branch: 'Calamba Branch', isActive: false }));
    await setDoc(doc(db, 'users/rider1'), profile('delivery', { branch: 'Calamba Branch' }));
    await setDoc(doc(db, 'users/cust1'), profile('customer'));
    await setDoc(doc(db, 'users/cust2'), profile('customer'));
    await setDoc(doc(db, 'users/ownerOff'), profile('owner', { isActive: false }));
    await setDoc(doc(db, 'products/p1'), { name: 'Cashew', price: 100 });
    await setDoc(doc(db, 'inventory/b1'), { branch: 'Calamba Branch', quantity: 10, productId: 'p1' });
    await setDoc(doc(db, 'inventory/b2'), { branch: 'Los Baños Hub', quantity: 10, productId: 'p1' });
    await setDoc(doc(db, 'orders/o1'), { customerId: 'cust1', branch: 'Calamba Branch', status: 'pending', riderId: 'rider1', total: 100 });
    await setDoc(doc(db, 'deliveries/d1'), { branch: 'Calamba Branch', riderId: 'rider1', customerId: 'cust1', status: 'assigned' });
    await setDoc(doc(db, 'refunds/r1'), { customerId: 'cust1', branch: 'Calamba Branch', status: 'pending', orderId: 'o1' });
    await setDoc(doc(db, 'refunds/r2'), { customerId: 'cust2', branch: 'Los Baños Hub', status: 'pending', orderId: 'o9' });
  });
});
const as = (uid, email) => env.authenticatedContext(uid, email ? { email } : {}).firestore();
// A user whose email Firebase has verified (link or Admin SDK).
const asVerified = (uid, email) => env.authenticatedContext(uid, { email, email_verified: true }).firestore();

// ---- users / roles -------------------------------------------------------
test('self-registration is denied until the email is verified', async () => {
  const unverified = as('newU', 'newU@x.com');
  await assertFails(setDoc(doc(unverified, 'users/newU'), { email: 'newU@x.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: serverTimestamp() }));
  const explicitlyFalse = env.authenticatedContext('newF', { email: 'newF@x.com', email_verified: false }).firestore();
  await assertFails(setDoc(doc(explicitlyFalse, 'users/newF'), { email: 'newF@x.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: serverTimestamp() }));
});
test('customer can self-register only as customer, active, verified, with own email', async () => {
  const db = asVerified('new1', 'new1@x.com');
  const base = { email: 'new1@x.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: serverTimestamp() };
  await assertSucceeds(setDoc(doc(db, 'users/new1'), base));
});
test('self-registration as owner/staff is denied', async () => {
  const db = asVerified('new2', 'new2@x.com');
  const base = { email: 'new2@x.com', name: 'N', phone: null, branch: null, isActive: true, createdAt: serverTimestamp() };
  await assertFails(setDoc(doc(db, 'users/new2'), { ...base, role: 'owner' }));
  await assertFails(setDoc(doc(db, 'users/new2'), { ...base, role: 'staff' }));
});
test('self-registration with someone else\'s email is denied', async () => {
  const db = asVerified('new3', 'new3@x.com');
  await assertFails(setDoc(doc(db, 'users/new3'), { email: 'ceo@x.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: serverTimestamp() }));
});
// A phone-verified user has no email; Firebase puts the verified number in the token.
const asPhone = (uid, phone) => env.authenticatedContext(uid, { phone_number: phone, firebase: { sign_in_provider: 'phone' } }).firestore();
const phoneBase = (phone) => ({ email: '', name: 'N', role: 'customer', phone, branch: null, isActive: true, createdAt: serverTimestamp() });
test('phone user can self-register only as customer with the number Firebase verified', async () => {
  const db = asPhone('ph1', '+639171234567');
  await assertSucceeds(setDoc(doc(db, 'users/ph1'), phoneBase('+639171234567')));
});
test('phone self-registration cannot claim another number, a role, a branch or an email', async () => {
  const db = asPhone('ph2', '+639171234567');
  await assertFails(setDoc(doc(db, 'users/ph2'), phoneBase('+639999999999')));
  await assertFails(setDoc(doc(db, 'users/ph2'), { ...phoneBase('+639171234567'), role: 'owner' }));
  await assertFails(setDoc(doc(db, 'users/ph2'), { ...phoneBase('+639171234567'), role: 'staff', branch: 'Calamba Branch' }));
  await assertFails(setDoc(doc(db, 'users/ph2'), { ...phoneBase('+639171234567'), branch: 'Calamba Branch' }));
  await assertFails(setDoc(doc(db, 'users/ph2'), { ...phoneBase('+639171234567'), email: 'ceo@x.com' }));
});
test('a non-phone sign-in cannot use the phone self-registration path', async () => {
  const db = env.authenticatedContext('ph3', { phone_number: '+639171234567', firebase: { sign_in_provider: 'password' } }).firestore();
  await assertFails(setDoc(doc(db, 'users/ph3'), phoneBase('+639171234567')));
});
test('user cannot change own role, branch or reactivate self', async () => {
  await assertFails(updateDoc(doc(as('staffA'), 'users/staffA'), { role: 'owner' }));
  await assertFails(updateDoc(doc(as('staffA'), 'users/staffA'), { branch: 'Los Baños Hub' }));
  await assertFails(updateDoc(doc(as('staffOff'), 'users/staffOff'), { isActive: true }));
  await assertSucceeds(updateDoc(doc(as('staffA'), 'users/staffA'), { name: 'New Name' }));
});
test('only owner can create staff profiles / read other users', async () => {
  const staff = { email: 's@x.com', name: 'S', role: 'staff', phone: null, branch: 'Calamba Branch', isActive: true, createdAt: serverTimestamp() };
  await assertSucceeds(setDoc(doc(as('owner1'), 'users/s9'), staff));
  await assertFails(setDoc(doc(as('staffA'), 'users/s10'), staff));
  await assertFails(getDoc(doc(as('cust1'), 'users/cust2')));
  await assertSucceeds(getDoc(doc(as('cust1'), 'users/cust1')));
});
test('a deactivated owner loses every owner privilege immediately', async () => {
  const db = as('ownerOff');
  await assertFails(getDoc(doc(db, 'users/cust1')));
  await assertFails(getDocs(collection(db, 'users')));
  await assertFails(setDoc(doc(db, 'users/s20'), { email: 's@x.com', name: 'S', role: 'staff', phone: null, branch: 'Calamba Branch', isActive: true, createdAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(db, 'users/cust1'), { name: 'Renamed' }));
  await assertFails(deleteDoc(doc(db, 'users/cust2')));
});
test('a deactivated user can still read their own profile (so the app can say why) but cannot edit it', async () => {
  await assertSucceeds(getDoc(doc(as('staffOff'), 'users/staffOff')));
  await assertFails(updateDoc(doc(as('staffOff'), 'users/staffOff'), { name: 'Sneaky' }));
  await assertSucceeds(getDoc(doc(as('ownerOff'), 'users/ownerOff')));
});
test('only an owner may delete a profile; nobody deletes their own', async () => {
  await assertFails(deleteDoc(doc(as('cust1'), 'users/cust1')));
  await assertFails(deleteDoc(doc(as('staffA'), 'users/staffA')));
  await assertSucceeds(deleteDoc(doc(as('owner1'), 'users/cust2')));
});
test('a client-supplied createdAt is rejected (it must be the server time)', async () => {
  const db = asVerified('new4', 'new4@x.com');
  await assertFails(setDoc(doc(db, 'users/new4'), { email: 'new4@x.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: new Date('2020-01-01') }));
});
test('unknown profile fields are rejected on create and on update', async () => {
  const db = asVerified('new6', 'new6@x.com');
  await assertFails(setDoc(doc(db, 'users/new6'), { email: 'new6@x.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: serverTimestamp(), isAdmin: true }));
  await assertFails(updateDoc(doc(as('cust1'), 'users/cust1'), { name: 'Ok', isAdmin: true }));
  await assertFails(updateDoc(doc(as('owner1'), 'users/cust1'), { isAdmin: true }));
});
test('name and phone are validated on self-edit', async () => {
  const db = as('cust1');
  await assertSucceeds(updateDoc(doc(db, 'users/cust1'), { phone: '09171234567' }));
  await assertFails(updateDoc(doc(db, 'users/cust1'), { phone: '0'.repeat(21) }));
  await assertFails(updateDoc(doc(db, 'users/cust1'), { name: '' }));
  await assertFails(updateDoc(doc(db, 'users/cust1'), { name: 'x'.repeat(101) }));
});
test('registration compares the email case-insensitively', async () => {
  const db = asVerified('new5', 'new5@x.com');
  await assertSucceeds(setDoc(doc(db, 'users/new5'), { email: 'New5@X.com', name: 'N', role: 'customer', phone: null, branch: null, isActive: true, createdAt: serverTimestamp() }));
});
test('owner must give staff and delivery accounts a branch', async () => {
  const base = { email: 'm@x.com', name: 'M', phone: null, isActive: true, createdAt: serverTimestamp() };
  await assertFails(setDoc(doc(as('owner1'), 'users/m1'), { ...base, role: 'staff', branch: null }));
  await assertFails(setDoc(doc(as('owner1'), 'users/m2'), { ...base, role: 'delivery', branch: null }));
  await assertSucceeds(setDoc(doc(as('owner1'), 'users/m3'), { ...base, role: 'delivery', branch: 'Calamba Branch' }));
});
test('owner may deactivate and reactivate an account; the account itself may not', async () => {
  await assertSucceeds(updateDoc(doc(as('owner1'), 'users/cust1'), { isActive: false }));
  await assertSucceeds(updateDoc(doc(as('owner1'), 'users/cust1'), { isActive: true }));
  await assertFails(updateDoc(doc(as('cust1'), 'users/cust1'), { isActive: false }));
});
test('non-owners cannot read other profiles or list users', async () => {
  for (const who of ['cust1', 'staffA', 'rider1']) {
    await assertFails(getDoc(doc(as(who), 'users/cust2')));
    await assertFails(getDocs(collection(as(who), 'users')));
  }
  await assertSucceeds(getDocs(collection(as('owner1'), 'users')));
});

// ---- every collection except `users` is denied to everyone ----------------
// The app never reads or writes these in Firestore (business data is in
// Supabase). Each payload below is one the OLD rules would have accepted from
// at least one of these roles, so a denial here is the lockdown working, not a
// malformed request. Includes owners and deactivated accounts.
const DENIED_COLLECTIONS = {
  products:   { id: 'p1', create: { name: 'Almond', price: 90 } },
  inventory:  { id: 'b1', create: { branch: 'Calamba Branch', quantity: 3, productId: 'p1' } },
  orders:     { id: 'o1', create: { customerId: 'cust1', branch: 'Calamba Branch', status: 'pending', total: 1 } },
  deliveries: { id: 'd1', create: { branch: 'Calamba Branch', riderId: 'rider1', customerId: 'cust1', status: 'assigned' } },
  refunds:    { id: 'r1', create: { customerId: 'cust1', status: 'pending', orderId: 'o1', amount: 100 } },
};
const PERSONAS = {
  'signed-out visitor': () => env.unauthenticatedContext().firestore(),
  'customer': () => as('cust1'),
  'staff': () => as('staffA'),
  'deactivated staff': () => as('staffOff'),
  'rider': () => as('rider1'),
  'owner': () => as('owner1'),
  'deactivated owner': () => as('ownerOff'),
};
for (const [col, cfg] of Object.entries(DENIED_COLLECTIONS)) {
  for (const [who, makeDb] of Object.entries(PERSONAS)) {
    test(`${col}: ${who} cannot read, list, create, update or delete`, async () => {
      const db = makeDb();
      await assertFails(getDoc(doc(db, col, cfg.id)));
      await assertFails(getDocs(collection(db, col)));
      await assertFails(setDoc(doc(db, col, 'zz-new'), cfg.create));
      await assertFails(updateDoc(doc(db, col, cfg.id), { status: 'x' }));
      await assertFails(deleteDoc(doc(db, col, cfg.id)));
    });
  }
}
test('regression: a customer can no longer write junk refund or order documents', async () => {
  await assertFails(setDoc(doc(as('cust1'), 'refunds/mine'), { customerId: 'cust1', status: 'pending' }));
  await assertFails(setDoc(doc(as('cust1'), 'orders/mine'), { customerId: 'cust1', branch: 'Calamba Branch', status: 'pending', total: 0, paymentStatus: 'paid' }));
});
test('regression: staff can no longer read another branch\'s refunds', async () => {
  await assertFails(getDoc(doc(as('staffA'), 'refunds/r2')));
  await assertFails(getDocs(collection(as('staffA'), 'refunds')));
});
test('regression: the public product catalogue is no longer readable from Firestore', async () => {
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'products/p1')));
});

// ---- default deny --------------------------------------------------------
test('unknown collections are denied to everyone, owners included', async () => {
  for (const [who, makeDb] of Object.entries(PERSONAS)) {
    const db = makeDb();
    await assertFails(getDoc(doc(db, 'secrets/x')));
    await assertFails(setDoc(doc(db, 'secrets/x'), { a: 1 }));
    await assertFails(getDoc(doc(db, 'users/someone/private/x')));
  }
});
