// npm run test:js   (node --test tests/js/sale-key.test.js)
// The website "New order" idempotency key (resources/js/sale-key.js), review fix 3.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { newSaleKey, noteFailedSale, outcomeUnknown, rotateSaleKey, startNewSale } from '../../resources/js/sale-key.js';

const counter = () => { let n = 0; return () => `key-${++n}`; };

test('a new sale gets a fresh key', () => {
    const make = counter();
    const s = { key: null, outcomeUnknown: true };
    assert.equal(startNewSale(s, make), 'key-1');
    assert.equal(s.outcomeUnknown, false);
});

test('changing lines / branch / method / cash makes a new key', () => {
    const make = counter();
    const s = {};
    startNewSale(s, make);
    assert.equal(rotateSaleKey(s, make), 'key-2');
    assert.equal(rotateSaleKey(s, make), 'key-3');
});

test('a refused sale (4xx) does not pin the key: the corrected sale gets a new one', () => {
    const make = counter();
    const s = {};
    startNewSale(s, make);
    noteFailedSale(s, Object.assign(new Error('Only 1 left'), { status: 422 }));
    assert.equal(s.outcomeUnknown, false);
    assert.equal(rotateSaleKey(s, make), 'key-2');
});

test('after an unknown outcome the key is kept, whatever changes, until a new sale', () => {
    const make = counter();
    const s = {};
    startNewSale(s, make);
    noteFailedSale(s, new TypeError('Failed to fetch')); // no status: the network failed
    assert.equal(rotateSaleKey(s, make), 'key-1');
    noteFailedSale(s, Object.assign(new Error('refused'), { status: 422 })); // a later clear "no" does not unpin it
    assert.equal(rotateSaleKey(s, make), 'key-1');
    assert.equal(startNewSale(s, make), 'key-2');
    assert.equal(rotateSaleKey(s, make), 'key-3');
});

test('which failures leave the outcome unknown', () => {
    assert.equal(outcomeUnknown(new TypeError('Failed to fetch')), true);
    assert.equal(outcomeUnknown({ status: 0 }), true);
    assert.equal(outcomeUnknown({ status: 408 }), true);
    assert.equal(outcomeUnknown({ status: 500 }), true);
    assert.equal(outcomeUnknown({ status: 504 }), true);
    assert.equal(outcomeUnknown({ status: 422 }), false);
    assert.equal(outcomeUnknown({ status: 403 }), false);
});

test('real keys are unique', () => {
    assert.notEqual(newSaleKey(), newSaleKey());
});
