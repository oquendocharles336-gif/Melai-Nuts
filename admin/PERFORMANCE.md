# Making the admin website fast on your own computer

Measured 2026-10-13 on a copy of this project, with a proxy that adds a 120 ms round trip in front of
the database to imitate a remote Supabase pooler. Your real round trip may be longer.
`php artisan melai:doctor` measures yours.

## What was slow

The business-data code was already lean: each page makes **1–3 Supabase round trips**, in batches, behind
a cache. What reproduced the 3–21 s pages was **Laravel's own tables (logins, sessions, cache) on the
remote database** (`DB_CONNECTION=pgsql` pointing at Supabase, or `SESSION_DRIVER` / `CACHE_STORE=database`).
Each page then runs 7–17 extra queries over the internet. Each costs about 3 round trips, plus a new SSL
connection per request. `php artisan serve` handles one request at a time on Windows, so the dashboard's
parallel calls queue behind each other.

| Route (warm; cold in brackets) | Before: Laravel tables remote | After: Supabase still remote¹ | After: local Supabase copy |
|---|---|---|---|
| /dashboard | 3.6 s (7.2 s) | **17 ms** (447 ms) | **19 ms** (78 ms) |
| /dashboard/overview.json | 3.6 s (7.8 s) | **17 ms** (602 ms) | **15 ms** (413 ms) |
| /ui/counts.json | 3.6 s (7.5 s) | **14 ms** (220 ms) | **15 ms** (105 ms) |
| /admin/users | 3.4 s | **65 ms** (203 ms) | **64 ms** (77 ms) |
| /receipts | 3.7 s | **21 ms** (143 ms) | **18 ms** (22 ms) |
| Dashboard's 4 parallel calls | 14.4 s | **84 ms** | **104 ms** |

¹ with `MELAI_ACCOUNT_CHECK_SECONDS=15`. With it at 0 (the default), add one round trip (~120 ms here)
to each warm number. "Cold" = the first load after the cache expires (`DASHBOARD_CACHE_SECONDS`).
Cold `overview.json` is mostly the SQL function `admin_portal_orders` (the 90-day order window: ~310 ms and
2 MB of JSON for ~2,000 orders). It is already indexed. A smaller `SUPABASE_ORDER_WINDOW_DAYS` makes it cheaper.

## Do this on your Windows machine

1. **Check:** `cd admin` then `php artisan melai:doctor`. It lists every problem it finds.
2. **`admin/.env`:** `DB_CONNECTION=sqlite`, `SESSION_DRIVER=file`, `CACHE_STORE=file`, `APP_DEBUG=false`,
   `LOG_LEVEL=warning`, `SUPABASE_DB_PERSISTENT=true`. Keep `SESSION_ENCRYPT=true` (it costs 0.07 ms).
   If you switch DB_CONNECTION to sqlite, run `php artisan migrate --seed --force` once. The seeder creates your
   admin login there. Other website logins stay in the old database (staff sign in with Firebase and are recreated).
3. **Optional, fastest:** a local copy of the Supabase database with sample data. Install PostgreSQL for
   Windows, then from the repository root:
   ```powershell
   $env:PGADMIN_URL = "postgresql://postgres:YOURPW@127.0.0.1:5432/postgres"
   powershell -ExecutionPolicy Bypass -File admin\database\local-supabase\setup.ps1
   ```
   Then switch the `SUPABASE_DB_*` lines in `.env` to the "LOCAL Supabase copy" block shown in
   `.env.example`. Keep your remote lines commented out so you can switch back, and run
   `php artisan optimize:clear` followed by `php artisan cache:clear`.
   The script uses your `ADMIN_EMAIL` / `ADMIN_STAFF_UID` for the owner row, so your usual sign-in works.
4. **Optional, while still on remote Supabase:** `MELAI_ACCOUNT_CHECK_SECONDS=15` (see the trade-off in `.env.example`).
5. **Caches:** `php artisan optimize` (config, routes, views, events). `start-admin.bat` already runs it.
   Re-run it after every `.env` change, because a cached config ignores `.env`.
   `composer.json` already sets `optimize-autoloader`. Run `composer dump-autoload -o` after adding classes.
6. **php.ini** (`php --ini` shows which file): `zend_extension=opcache`, `opcache.enable=1`,
   `opcache.memory_consumption=256`, `opcache.validate_timestamps=1`, `opcache.revalidate_freq=2`,
   `realpath_cache_size=4096K`, and comment out any `zend_extension=xdebug`. `opcache.enable_cli=0` is fine:
   `php artisan serve` runs as `cli-server`, where OPcache still works (tested).
7. **Windows Defender** (admin PowerShell): `Add-MpPreference -ExclusionPath "C:\path\to\Melai-Nuts-master"`.
   Check with `Get-MpPreference | Select -Expand ExclusionPath`. Keep the project **outside OneDrive**.
8. **Parallel requests:** `PHP_CLI_SERVER_WORKERS` does nothing on Windows, and Laravel also ignores it
   without `--no-reload`. For real parallelism use **Laragon** (Apache/Nginx + PHP; point the site at
   `admin\public`) or **Herd for Windows** (`herd link` inside `admin`). With the fixes above, single-threaded
   `php artisan serve` is also fine (the parallel burst takes 84–104 ms).
9. **Assets:** use `npm run build`. If `admin/public/hot` exists, a `npm run dev` server is in use; stop it
   and delete the file unless you are editing CSS/JS.

## Changes in this patch (and how to undo each)

| Change | Files | Undo |
|---|---|---|
| `php artisan melai:doctor` (read-only speed check) | `app/Console/Commands/PerfDoctorCommand.php` | delete the file |
| TCP keepalives on the Supabase connection, so a silently dropped kept-open connection can't hang a page for ~20 s | `app/Database/PostgresKeepaliveConnector.php`, `config/database.php`, `AppServiceProvider.php` | `SUPABASE_DB_KEEPALIVES_IDLE=0`, or remove the `db.connector.pgsql` binding |
| Opt-in reuse of the account check for page loads (GET only; changes always re-check) | `StaffIdentity.php`, `config/melai.php` | `MELAI_ACCOUNT_CHECK_SECONDS=0` (the default) |
| Users directory and receipts list cached like the dashboard (fresh only; cleared by any change made on the website) | `Admin/UserController.php`, `PurchaseReceiptController.php` | `DASHBOARD_CACHE_SECONDS=0`, or revert the two `Swr::remember` wraps |
| Cache keys include which Supabase database answered (local copy and real data never mix) | `app/Support/Swr.php` | revert `key()` / `target()` |
| Local Supabase copy plus sample data (never touches Supabase; refuses a `supabase` URL) | `database/local-supabase/*` | `drop database melai_local` on your local Postgres |
| `.env.example` notes (local switch, `--no-reload`, quote passwords that contain `#`) | `.env.example` | revert |
| Instant tab switching: pages you already opened (last 5 min) appear at once from browser memory, then refresh in the background; any change made on the website clears them | `resources/js/ui.js` (then `npm run build`) | revert `ui.js` and rebuild |
| Tests for the above | `tests/Feature/LocalSpeedSettingsTest.php` | delete |

No Supabase migration, data or production setting was changed. All 268 tests pass (215 + 53 Supabase
integration tests on a local Postgres).
