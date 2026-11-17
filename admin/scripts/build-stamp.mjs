// Records WHICH sources public/build was made from, so start-admin.bat can tell a stale build apart
// from a fresh one by content instead of file dates. (File dates are unreliable: unzipping a newer
// copy of the project keeps the archive's old dates, so an old build looked "newer" than the new
// code and was served without the Product photos script.)
//
//   node scripts/build-stamp.mjs          write public/build/.sources-hash (run by `npm run build`)
//   node scripts/build-stamp.mjs --check  exit 1 when public/build is missing or was built from other sources
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const stamp = join(root, 'public', 'build', '.sources-hash');

function files(dir) {
    return readdirSync(dir).flatMap((name) => {
        const path = join(dir, name);
        return statSync(path).isDirectory() ? files(path) : [path];
    });
}

const sources = [
    ...files(join(root, 'resources', 'js')),
    ...files(join(root, 'resources', 'css')),
    ...['package.json', 'package-lock.json', 'vite.config.js'].map((f) => join(root, f)).filter(existsSync),
].map((p) => relative(root, p).split('\\').join('/')).sort();

const hash = createHash('sha256');
for (const rel of sources) {
    // Line endings do not change the build: a Windows checkout must not look different.
    hash.update(rel + '\0' + readFileSync(join(root, rel), 'utf8').replace(/\r\n/g, '\n') + '\0');
}
const digest = hash.digest('hex');

if (process.argv.includes('--check')) {
    const built = existsSync(join(root, 'public', 'build', 'manifest.json')) && existsSync(stamp)
        ? readFileSync(stamp, 'utf8').trim() : '';
    if (built !== digest) {
        console.log('public/build is missing or out of date: run npm run build');
        process.exit(1);
    }
    console.log('public/build is up to date');
} else {
    writeFileSync(stamp, digest + '\n');
}
