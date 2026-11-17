// Products page > Photos: the browser-side checks and the remembered "Allow" choice.
import { test } from 'node:test';
import assert from 'node:assert/strict';

// The few browser pieces the helpers touch: the signed-in user's id and localStorage.
const store = new Map();
globalThis.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
};
let user = '7';
globalThis.document = { querySelector: (sel) => (sel === 'meta[name="melai-user"]' ? { content: user } : null) };

const { checkFile, readPhotoAccess, savePhotoAccess, clearPhotoAccess } = await import('../../resources/js/product-photos.js');

const file = (name, type, size) => new File([new Uint8Array(size)], name, { type });

test('JPG, PNG and WEBP up to 5 MB are accepted', () => {
    assert.equal(checkFile(file('a.jpg', 'image/jpeg', 1000)), null);
    assert.equal(checkFile(file('b.png', 'image/png', 5 * 1024 * 1024)), null);
    assert.equal(checkFile(file('c.webp', 'image/webp', 10)), null);
});

test('other file types and files over 5 MB get a clear reason', () => {
    assert.match(checkFile(file('notes.txt', 'text/plain', 10)), /is not a JPG, PNG or WEBP photo/);
    assert.match(checkFile(file('IMG_1.HEIC', 'image/heic', 10)), /HEIC photo/);
    assert.match(checkFile(file('big.jpg', 'image/jpeg', 5 * 1024 * 1024 + 1)), /up to 5 MB/);
});

test('the Allow choice is remembered per signed-in user and can be reset', () => {
    assert.equal(readPhotoAccess(), null);
    savePhotoAccess();
    assert.equal(readPhotoAccess().allowed, true);
    user = '8';
    assert.equal(readPhotoAccess(), null, 'another user is asked again');
    user = '7';
    clearPhotoAccess();
    assert.equal(readPhotoAccess(), null);
});

test('blocked storage (private mode) means "ask again", never an error', () => {
    const real = globalThis.localStorage;
    globalThis.localStorage = { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); }, removeItem() { throw new Error('blocked'); } };
    try {
        assert.equal(readPhotoAccess(), null);
        assert.equal(savePhotoAccess().allowed, true);
        clearPhotoAccess();
    } finally {
        globalThis.localStorage = real;
    }
});
