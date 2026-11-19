#!/usr/bin/env python3
"""Runs moderation/test_cases.json against every copy of the blocked-words check it can reach.

    python3 scripts/test_blocked_words.py                 Python reference, JavaScript (node), PHP
    DATABASE_URL=postgresql://... python3 scripts/test_blocked_words.py   ... and the database copy

The app's Dart copy runs the same cases in `flutter test test/blocked_words_test.dart`.
Also fails when the generated copies are out of date (scripts/sync_blocked_words.py --check).
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
from blocked_words_ref import load  # noqa: E402

CASES = json.load(open(os.path.join(ROOT, 'moderation', 'test_cases.json'), encoding='utf-8'))


def report(name, contains) -> bool:
    missed = [t for t in CASES['blocked'] if not contains(t)]
    false_pos = [t for t in CASES['allowed'] if contains(t)]
    ok = not missed and not false_pos
    print(f"{'PASS' if ok else 'FAIL'} {name}" + ('' if ok else f'  missed={missed} false_positives={false_pos}'))
    return ok


def run_batch(cmd, cwd=None):
    texts = CASES['blocked'] + CASES['allowed']
    out = subprocess.run(cmd, input=json.dumps(texts), capture_output=True, text=True, cwd=cwd, check=True).stdout
    answers = dict(zip(texts, json.loads(out)))
    return lambda t: answers[t]


def main() -> int:
    ok = report('python reference', load().contains)

    if shutil.which('node'):
        js = ("import {makeBlockedWordsChecker} from './admin/resources/js/blocked-words.js';"
              "import {readFileSync} from 'node:fs';"
              "const c = makeBlockedWordsChecker(JSON.parse(readFileSync('moderation/blocked_words.json','utf8')));"
              "const t = JSON.parse(readFileSync(0,'utf8')); console.log(JSON.stringify(t.map(c)));")
        ok &= report('javascript (admin/resources/js/blocked-words.js)', run_batch(['node', '--input-type=module', '-e', js], ROOT))

    if shutil.which('php') and os.path.exists(os.path.join(ROOT, 'admin', 'vendor', 'autoload.php')):
        php = ("require 'vendor/autoload.php'; $app = require 'bootstrap/app.php';"
               "$app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap();"
               "echo json_encode(array_map(fn ($t) => App\\Support\\BlockedWords::contains($t), json_decode(stream_get_contents(STDIN), true)));")
        ok &= report('php (admin/app/Support/BlockedWords.php)', run_batch(['php', '-r', php], os.path.join(ROOT, 'admin')))

    url = os.environ.get('DATABASE_URL')
    if url and shutil.which('psql'):
        def sql_contains(t):
            out = subprocess.run(['psql', '-X', '-At', url, '-c', 'select public.contains_blocked_words(:\'t\')', '-v', f't={t}'],
                                 capture_output=True, text=True)
            if out.returncode != 0:  # older psql: no variables with -c
                q = "'" + t.replace("'", "''") + "'"
                out = subprocess.run(['psql', '-X', '-At', url, '-c', f'select public.contains_blocked_words({q})'], capture_output=True, text=True, check=True)
            return out.stdout.strip() == 't'
        ok &= report('database (public.contains_blocked_words)', sql_contains)

    sync = subprocess.run([sys.executable, os.path.join(ROOT, 'scripts', 'sync_blocked_words.py'), '--check'])
    ok &= sync.returncode == 0
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
