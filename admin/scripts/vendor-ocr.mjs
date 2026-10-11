// Copies Tesseract.js (OCR on the Receiving page) from node_modules into public/vendor/tesseract,
// so the browser loads it from THIS site, never from a CDN (the CSP allows no other script origin).
// Runs after `vite build` (package.json "build"). Versions are pinned in package.json.
import { copyFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const nm = join(root, 'node_modules');
const out = join(root, 'public', 'vendor', 'tesseract');

const files = [
  ['tesseract.js/dist/tesseract.min.js', 'tesseract.min.js'],
  ['tesseract.js/dist/worker.min.js', 'worker.min.js'],
  // LSTM engine only (the page uses OEM 1), with and without SIMD.
  ['tesseract.js-core/tesseract-core-lstm.wasm.js', 'core/tesseract-core-lstm.wasm.js'],
  ['tesseract.js-core/tesseract-core-simd-lstm.wasm.js', 'core/tesseract-core-simd-lstm.wasm.js'],
  ['@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz', 'lang/eng.traineddata.gz'],
];

let missing = 0;
for (const [from, to] of files) {
  const src = join(nm, from);
  if (!existsSync(src)) {
    console.error(`vendor-ocr: missing ${from} (run npm ci)`);
    missing++;
    continue;
  }
  const dest = join(out, to);
  mkdirSync(dirname(dest), { recursive: true });
  copyFileSync(src, dest);
}
if (missing) process.exit(1);
console.log(`vendor-ocr: ${files.length} files -> public/vendor/tesseract`);
