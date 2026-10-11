# Melai Nuts — QA checklist (before every release / panel demo)

Tick every line on a **release build** (`flutter build apk --release` or `flutter run --release`) on
a real Android phone, plus a tablet or the web build for layout. Use a test Supabase project with the
latest migrations; never test on live customer data.

## 0. Automated (must be green first)

| Command | What it proves |
|---|---|
| `flutter gen-l10n && flutter analyze --no-fatal-infos --fatal-warnings` | Code compiles; no warnings |
| `flutter test` | Validators, local DB, list tools, sync queue, POS offline queue, checkout recovery, route access, legal re-acceptance, responsive layouts (360/768/1280), translations complete |
| `bash scripts/run-sql-tests.sh` | RLS, grants, CHECK constraints, rate limits, paging functions, legal acceptance (`supabase/tests/*.sql`) |
| `python3 scripts/check_no_fixture_data.py && python3 -m unittest scripts/test_check_no_fixture_data.py` | No demo data; no key-shaped secret anywhere |
| `bash scripts/build-resync.sh --check` | The repair script contains every migration |
| `cd admin && php artisan test` | Admin website: auth, 2FA required, throttling, FormRequests, terms |

## 1. Input validation (Criterion 1)

- [ ] Register with a 1-letter name, a name with digits, a 7-character password, `Password1!`, a password containing your own name → each blocked with a clear message under the field.
- [ ] Name with `ñ` / `é` (e.g. “Peña”) → accepted.
- [ ] Phone `0917 123 4567`, `+63 917 123 4567`, `09171234567` → accepted and shown the same way later; `0817…`, 10 digits → refused.
- [ ] Letters cannot be typed in quantity / price / code fields; price refuses a 3rd decimal.
- [ ] Paste 2,000 characters into a notes field → cut at the limit, counter visible.
- [ ] Receive batch: future received date, expiry today or before received date → refused.
- [ ] Submit an empty form → first bad field focused and scrolled into view.

## 2. Security (Criterion 2)

- [ ] `grep -R "AIza" .` in the repo finds nothing; the app still starts with your own `env/` files.
- [ ] Release APK: `adb shell run-as ph.melainuts.app` fails (not debuggable).
- [ ] `adb logcat` during sign-in, checkout and an error shows no e-mail, phone, address or token.
- [ ] Customer A cannot open customer B's order by ID (deep link / changed request) → “not found”.
- [ ] Staff of branch A cannot see branch B's stock; a deactivated account is signed out.
- [ ] Try 11 voucher codes quickly → “too many attempts”; 4 refund requests in 30 min → refused.
- [ ] Admin website: owner without 2-step verification is sent to set it up; 70 quick saves → 429 page.

## 3. Local and cloud data (Criterion 3)

- [ ] Sign in, open orders / points / notifications, turn on airplane mode, kill and reopen the app → lists show at once with “Saved data · last updated …”.
- [ ] Search order history offline → results from the device.
- [ ] Back online → banner disappears, data refreshes, nothing duplicated.
- [ ] Sign out, sign in as another customer → none of the first customer's data visible (also offline).

## 4. Search, sort, filter (Criterion 4)

- [ ] Order history: search by order ID and branch; sort newest / oldest / amount; filter status and date; chips removable; “Clear filters” on no results.
- [ ] Points history: earned / redeemed filter; sort by points.
- [ ] Notifications: unread filter, type filter, search.
- [ ] Staff transactions: search by customer / phone / item; cash vs non-cash; POS vs online.
- [ ] Inventory list: search SKU; filter Out / Low / Normal; sort by quantity.
- [ ] Product search: category + price filters; sort by price and name.
- [ ] Type fast in any search box → only the last text is searched (no flicker of old results).

## 5. Edit / delete confirmation (Criterion 5)

- [ ] Delete address, remove cart line (Undo works), clear cart, delete notification (swipe and detail), deactivate user, cancel order, void sale, stock adjustment, transfer send/accept/reject, product deactivate → each asks first; **Cancel** is the default and changes nothing.
- [ ] Edit profile, change something, press Back → “Discard changes?”.
- [ ] Admin website: every destructive button opens the confirm modal (no browser `confirm()`).

## 6. Field information (Criterion 6)

- [ ] Every field has a visible label, required `*` / “(optional)”, a format hint where useful, and the right keyboard.
- [ ] Terms checkbox unticked by default; notifications consent separate and optional.

## 7. UI / UX (Criterion 7)

- [ ] Phone (360 dp), tablet (768), web (1280): no overflow stripes; product grid 2 / 3+ columns.
- [ ] Android font size “Largest”: text wraps, buttons still reachable.
- [ ] TalkBack: icon buttons announce their tooltip; status chips read their text.
- [ ] Reduce motion on → no slide-in animations.

## 8. Error handling (Criterion 8)

- [ ] Airplane mode on any list → error with Retry (or saved data); Retry works after reconnecting.
- [ ] Stop the Supabase project / wrong URL in `env/` → friendly “could not start” screen, no raw error text in release.
- [ ] Server refuses an action (e.g. redeem with too few points) → plain message, nothing changed locally.

## 9. Pagination (Criterion 9)

- [ ] With > 60 orders: history loads 25, more on scroll, “end of list” at the bottom, pull to refresh restarts.
- [ ] Admin website: users, refunds, payments and activity log show 25 per page with page links; user search is sent to the database (`owner_all_users`).

## 10. Stability (Criterion 10)

- [ ] Double-tap Place order / Pay / Confirm payment / Submit refund → exactly one order / action.
- [ ] Kill the app right after Place order, reopen → the order is found (no duplicate, no lost order).
- [ ] POS: sell offline, kill app, reopen online → sale sent once (same checkout key).
- [ ] Rotate the phone / resize the web window on forms → typed input kept.
- [ ] Leave the app 30 min in background, return → still signed in or a clean sign-in prompt; no crash.
- [ ] Crashlytics shows no new fatal issues after the test run.

## 11. Terms and permissions (Criterion 11)

- [ ] Terms and Privacy open from register, settings and the admin footer, before signing in.
- [ ] Bump `LegalConfig.termsVersion` in a test build → signed-in users are asked to accept again.
- [ ] Fresh install: no permission prompt at start. Camera asked only at “Scan” / proof photo, location only at “Use my location” / start delivery, notifications only after the first order — each after a short explanation.
- [ ] Deny each → app keeps working; the dialog offers “Open settings”; Settings > Permissions shows the status.
