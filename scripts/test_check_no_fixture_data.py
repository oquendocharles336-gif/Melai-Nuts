"""Tests for scripts/check_no_fixture_data.py:  python3 -m unittest scripts/test_check_no_fixture_data.py"""
import os
import subprocess
import sys
import tempfile
import unittest

GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_no_fixture_data.py")


def run(tree: dict) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as root:
        for rel, text in tree.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        return subprocess.run([sys.executable, "-I", GUARD], env={**os.environ, "MELAI_GUARD_ROOT": root},
                              capture_output=True, text=True)


class GuardTest(unittest.TestCase):
    def test_clean_tree_passes(self):
        r = run({"lib/a.dart": "final x = repo.fetch(); // never a fake photo\n",
                 "test/support/staff_fixtures.dart": "class FakeAuth {} // fixtures live in tests\n"})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_fixture_word_in_code_fails(self):
        r = run({"lib/a.dart": "final ok = 1;\nfinal products = mockProducts;\n"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("lib/a.dart:2", r.stdout)

    def test_fixture_class_and_seed_string_fail_even_in_comments(self):
        r = run({"admin/app/X.php": "<?php // uses MockDataSource\n",
                 "supabase/migrations/1.sql": "-- insert 'Fresh Batch Every Friday'\n"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("MockDataSource", r.stdout)
        self.assertIn("Fresh Batch Every Friday", r.stdout)

    def test_real_key_in_example_file_fails(self):
        r = run({"env/firebase.example.json": '{"K": "AIza' + "x" * 35 + '"}\n'})
        self.assertEqual(r.returncode, 1)
        self.assertIn("key/token", r.stdout)

    def test_key_anywhere_in_repo_fails_even_outside_shipping_code(self):
        # docs, tests and android/app/src are not "shipping code" but a committed key is still public
        for path in ("docs/notes.md", "test/a_test.dart", "android/app/src/google-services.json.example"):
            r = run({path: '"current_key": "AIza' + "B" * 35 + '"\n'})
            self.assertEqual(r.returncode, 1, path)
            self.assertIn(path, r.stdout)
            self.assertNotIn("B" * 35, r.stdout, "the full key must never be echoed into CI logs")

    def test_other_secret_shapes_fail(self):
        jwt = "eyJ" + "a" * 20 + ".eyJ" + "b" * 20 + "." + "c" * 20
        for text in (f"key = '{jwt}'", "STRIPE=sk_live_" + "9" * 24, "k=sb_secret_" + "z" * 20,
                     "SUPABASE_SERVICE_ROLE_KEY=" + "q" * 40, "-----BEGIN " + "PRIVATE KEY-----"):
            r = run({"scripts/x.sh": text + "\n"})
            self.assertEqual(r.returncode, 1, text)

    def test_placeholders_and_mentions_pass(self):
        r = run({"env/firebase.example.json": '{"FIREBASE_API_KEY_WEB": "YOUR_FIREBASE_WEB_API_KEY"}\n',
                 "SECURITY.md": "Never put the `service_role` key in the app. SUPABASE_SERVICE_ROLE_KEY=\n",
                 "supabase/migrations/1.sql": "grant execute on function f() to service_role;\n"})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_allowlist_needs_a_reason_and_allows_the_line(self):
        r = run({"lib/a.dart": "final d = dummyVariable;\n", "scripts/hardcoded-data-allowlist.txt": "lib/a.dart|dummyVariable|\n"})
        self.assertNotEqual(r.returncode, 0)
        r = run({"lib/a.dart": "final d = dummy;\n", "scripts/hardcoded-data-allowlist.txt": "lib/a.dart|dummy|statistics term\n"})
        self.assertEqual(r.returncode, 0, r.stdout)


if __name__ == "__main__":
    unittest.main()
