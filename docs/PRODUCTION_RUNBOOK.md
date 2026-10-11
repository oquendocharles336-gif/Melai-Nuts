# Melai Nuts — production runbook

## 1. Seeded demo records clean-up (staging first)

**State of the live project (read-only check, 2026-10-18):** 12 seeded stock rows at 50 units, 5 seeded
products active, 3 seeded rewards and the "Fresh Batch Every Friday" promotion active, the 3 branches
still on the seeded address, the 4 demo orders ORD-1001…1004 (of 5 orders in total), the online-payment
switch present, `business_settings` not created yet (migrations 20261018 / 20261019 not applied).

**There is no staging project yet** (the Supabase project `Melai-Nuts-Retail` has only its `main`
branch, status `MIGRATIONS_FAILED` for Git-based branching). Nothing was run on production. The clean-up
was run on a local database that reproduces the seeded rows (`supabase/tests/cleanup_seeded_demo_records_test.sh`,
15/15) — that is a rehearsal, not a staging run.

### 1a. Create staging (once)

Either (A) Supabase dashboard > Branches > *Create branch* **with data** (paid feature), or (B) a new
free project restored from a backup of production:

```bash
# B: dump production (Supabase dashboard > Connect > Session pooler URL)
pg_dump "$PROD_URL" --no-owner --no-privileges -Fc -f melai-prod.dump
pg_restore --no-owner --no-privileges -d "$STAGING_URL" melai-prod.dump
```

### 1b. On STAGING, in this order

| Step | Run | Check |
|---|---|---|
| 1 | `supabase/repair/20261010_resync_live_database.sql` (all migrations, idempotent) | finishes without error; `select public.get_loyalty_earn_rate()` still returns the current rate |
| 2 | `supabase/repair/20261010_review_seeded_demo_records.sql` | lists the rows above |
| 3 | clean-up section **A** (stock), ROLLBACK first, then COMMIT | 12 rows listed, then 0 left |
| 4 | section **B** (hide 3 never-sold products) | 3 rows; the 2 sold products stay — check their price |
| 5 | section **C** (deactivate rewards + promotion), optional **C2** (delete) | 3 + 1 rows |
| 6 | section **D** (type the REAL branch address / phone / hours) | the `select` shows your values |
| 7 | section **F** | all counters 0, `flagged_orders_kept` = 4 |
| 8 | Section **E**: decide about ORD-1001…1004 | refund them in the app / website only if they were tests |
| 9 | Open the app and the admin website against staging | catalog shows only real products; Business settings asks you to confirm the carried-over values |

### 1c. On PRODUCTION (same order)

1. Quiet hour; Supabase dashboard > Database > Backups: note the latest backup / PITR time.
2. Steps 1–7 above, each section ROLLBACK first, read the output, then COMMIT.
3. Admin website > Settings > **Business settings**: confirm or change the carried-over values,
   set sales targets if wanted, check each branch's delivery fee.
4. Loyalty page: confirm the earn and redeem rules.
5. Staff count the shelves and record real stock with **Receive Stock**.
6. Re-run section F and keep its output with the date.

Rollback plan: every section is a single transaction; if something looks wrong after COMMIT,
restore from the backup / PITR point noted in step 1 (Supabase dashboard > Database > Backups).
