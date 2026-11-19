// npm run test:js
// The browser copy of the blocked-words check (resources/js/blocked-words.js) against the shared
// list and the shared test cases in moderation/ (the same cases the PHP, SQL and Dart copies use).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { makeBlockedWordsChecker } from '../../resources/js/blocked-words.js';

const read = (p) => JSON.parse(readFileSync(new URL(p, import.meta.url), 'utf8'));
const contains = makeBlockedWordsChecker(read('../../../moderation/blocked_words.json'));
const cases = read('../../../moderation/test_cases.json');

test('every blocked case is caught', () => {
    assert.deepEqual(cases.blocked.filter((t) => !contains(t)), []);
});

test('innocent text is never blocked', () => {
    assert.deepEqual(cases.allowed.filter((t) => contains(t)), []);
});
