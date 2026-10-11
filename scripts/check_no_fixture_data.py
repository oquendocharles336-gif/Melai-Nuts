#!/usr/bin/env python3
"""
Melai Nuts — hardcoded-data guard (owner decision: NO HARDCODED DATA).

Fails (exit 1) when code that ships contains:
  * test-fixture class names (MockDataSource, FakeSupabase, staff_fixtures, ...),
  * the words demo / dummy / sample / mock / fake / lorem in code (explanatory comments are
    not counted; fixture names and strings below are counted everywhere),
  * known fixture or old-seed strings (fixture people, the old demo catalog, branch
    addresses, demo orders, demo credentials, personal e-mails, the Firebase project id),
  * real-looking secrets (Firebase/Google API keys, JWTs, Stripe/HitPay-style live keys,
    Supabase secret keys, a filled-in service_role key). Secrets are checked in EVERY
    text file of the repository (tests and docs included), not only shipping code,
    because a key committed anywhere is public.

Shipping code = lib/, admin/app, admin/config, admin/routes, admin/resources, admin/database,
admin/public/js, supabase/schema.sql, supabase/migrations, supabase/functions, functions/ (not
its tests), hardware/, env/*.example.json, android/app/*.example, admin/.env.example.
Test folders (test/, admin/tests, supabase/tests, functions/test, firestore-tests) are where
fixtures belong and are not scanned.

A line can be allowed only through scripts/hardcoded-data-allowlist.txt
("<path glob>|<python regex>|<reason>"); every entry needs a reason.

    python3 scripts/check_no_fixture_data.py          # from the repository root
"""
from __future__ import annotations

import fnmatch
import os
import re
import sys

ROOT = os.environ.get("MELAI_GUARD_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCAN = [
    "lib", "admin/app", "admin/config", "admin/routes", "admin/resources", "admin/database",
    "admin/public/js", "supabase/schema.sql", "supabase/migrations", "supabase/functions",
    "functions", "hardware", "env", "android/app/google-services.json.example", "admin/.env.example",
]
SKIP_DIRS = {"node_modules", "vendor", "test", "tests", "build", ".dart_tool", "storage"}
EXTS = {".dart", ".php", ".js", ".ts", ".sql", ".json", ".example", ".ino", ".h", ".cpp", ".yaml", ".yml", ".md", ".txt", ""}

WORDS = re.compile(r"(?i:\b(demo|dummy|dummies|sample|samples|mock|mocked|mocks|fake|faked|fakes|lorem)\b)"
                   r"|\b(?:demo|dummy|sample|mock|fake|lorem)(?=[A-Z_0-9])"          # mockProducts, demo_rows
                   r"|\b(?:Demo|Dummy|Sample|Mock|Fake|Lorem)[A-Z0-9_]\w*")  # MockOrders
FIXTURE_CLASSES = re.compile(
    r"\b(MockDataSource|MockPlatform|FakeSupabase|FakeFirebase|PerfSupabase|SalesFixture|UsesFakeSupabase|"
    r"staff_fixtures|StaffFixtures|test_db\.dart|TestDb)\b")
KNOWN_STRINGS = [
    # people / accounts used only by the test fixtures
    "Cora Cashier", "Lito Cashier", "Dario Rider", "Carla Customer", "Melai Owner", "@melainuts.test",
    "uid-owner", "uid-cal", "CARD-0042",
    # the old demo seed (catalog, rewards, promotion, branch details, orders, credentials)
    "Roasted Cashew", "Chili Garlic Peanuts", "Mixed Nuts & Raisins", "Melai Nuts Gift Box",
    "Fresh Batch Every Friday", "Free Delivery Voucher", "Free 100g Roasted Cashew",
    "Poblacion Terminal", "Lopez Ave", "(049) 502-1187", "(049) 536-4420", "(049) 501-7765",
    "ORD-1001", "ORD-1002", "ORD-1003", "ORD-1004", "ChangeMe#2026", "admin@melainuts",
    "Maria Melai", "MN-OWNER-2024", "support@melainuts",
    # personal data and the real project's identifiers (they live only in local env files)
    "kanzeki", "melai-nuts-app-2026", "865090291609", "ieakrniwpagnowliyrtq",
    # invented sample people in input hints
    "Elena Santos", "Juan dela Cruz", "elena@example.com",
]
SECRETS = re.compile(
    r"(AIza[0-9A-Za-z_\-]{35}"                                    # Google / Firebase API key
    r"|eyJ[0-9A-Za-z_\-]{8,}\.eyJ[0-9A-Za-z_\-]{8,}\.[0-9A-Za-z_\-]{8,}"  # any JWT (anon or service_role)
    r"|eyJhbGciOi[0-9A-Za-z_\-]{10,}\.[0-9A-Za-z_\-]{10,}"         # JWT header + payload
    r"|\b[rs]k_live_[0-9A-Za-z]{8,}"                              # live secret / restricted keys
    r"|\bsb_secret_[0-9A-Za-z_\-]{8,}"                            # Supabase secret API key
    r"|\bservice_role[_A-Za-z]*\s*[=:]\s*[\"']?(?:eyJ|sb_secret_)[0-9A-Za-z_\-.]{8,}"  # filled service_role key
    r"|SERVICE_ROLE_KEY\s*[=:]\s*[\"']?[0-9A-Za-z_\-.]{20,}"       # SUPABASE_SERVICE_ROLE_KEY=<value>
    r"|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)")
# The secrets rule runs over the whole repository except these generated / third-party folders.
SECRET_SKIP_DIRS = {".git", "node_modules", "vendor", "build", ".dart_tool", "storage", "Pods", ".gradle",
                    "generated", "ephemeral"}
SECRET_SKIP_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".ttf", ".otf", ".woff", ".woff2",
                    ".jar", ".zip", ".pdf", ".so", ".dll", ".exe", ".lock"}


COMMENT_START = ("//", "--", "#", "*", "/*", "{{--", "<!--")


def code_part(line: str, ext: str) -> str:
    """The line without comments (the fixture WORDS rule ignores explanatory comments)."""
    t = line.strip()
    if t.startswith(COMMENT_START):
        return ""
    for marker in ((" -- ",) if ext == ".sql" else ()) + (" // ", " # " if ext in (".php", ".yaml", ".yml") else " // "):
        if marker in line:
            line = line.split(marker, 1)[0]
    return line


def load_allowlist() -> list[tuple[str, re.Pattern, str]]:
    path = os.path.join(ROOT, "scripts", "hardcoded-data-allowlist.txt")
    out = []
    if not os.path.exists(path):
        return out
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("|", 2)
        if len(parts) != 3 or not parts[2].strip():
            sys.exit(f"hardcoded-data-allowlist.txt:{n}: need '<path glob>|<regex>|<reason>'")
        out.append((parts[0].strip(), re.compile(parts[1].strip()), parts[2].strip()))
    return out


def files():
    for entry in SCAN:
        full = os.path.join(ROOT, entry)
        if os.path.isfile(full):
            yield entry
            continue
        for dirpath, dirnames, filenames in os.walk(full):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
            for f in filenames:
                rel = os.path.relpath(os.path.join(dirpath, f), ROOT).replace(os.sep, "/")
                if rel.startswith("functions/") and (f.endswith(".test.js") or "/test/" in rel):
                    continue
                if os.path.splitext(f)[1] in EXTS or f.endswith(".example"):
                    yield rel


def all_files():
    """Every text file in the repository, for the secrets rule."""
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SECRET_SKIP_DIRS]
        for f in filenames:
            if os.path.splitext(f)[1].lower() in SECRET_SKIP_EXTS:
                continue
            yield os.path.relpath(os.path.join(dirpath, f), ROOT).replace(os.sep, "/")


def secret_problems(allow) -> list[str]:
    out = []
    for rel in all_files():
        try:
            text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            m = SECRETS.search(line)
            if not m:
                continue
            if any(fnmatch.fnmatch(rel, g) and r.search(line) for g, r, _ in allow):
                continue
            shown = m.group(0)[:8] + "…"  # never echo the whole secret into CI logs
            out.append(f"{rel}:{n}: a real-looking key/token ({shown}) — remove it, then rotate it")
    return out


def main() -> int:
    allow = load_allowlist()
    problems = []
    for rel in files():
        try:
            text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            hits = []
            if m := WORDS.search(code_part(line, os.path.splitext(rel)[1])):
                hits.append(f"word '{m.group(0)}'")
            if m := FIXTURE_CLASSES.search(line):
                hits.append(f"fixture class '{m.group(0)}'")
            for s in KNOWN_STRINGS:
                if s.lower() in line.lower():
                    hits.append(f"fixture/seed string '{s}'")
            if not hits:
                continue
            if any(fnmatch.fnmatch(rel, g) and r.search(line) for g, r, _ in allow):
                continue
            problems.append(f"{rel}:{n}: {', '.join(hits)}\n    {line.strip()[:160]}")
    problems += secret_problems(allow)
    if problems:
        print("Hardcoded / fixture data found in shipping code (move it to tests, a database setting or an env file):\n")
        print("\n".join(problems))
        print(f"\n{len(problems)} problem(s).")
        return 1
    print("hardcoded-data guard: OK (no fixture classes, fixture words, seed strings or keys in shipping code)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
