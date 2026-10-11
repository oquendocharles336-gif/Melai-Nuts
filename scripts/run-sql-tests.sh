#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — build a throwaway LOCAL database from schema.sql + every migration
# and run every SQL suite and concurrency script in supabase/tests/.
#
#   PGADMIN_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres \
#     bash scripts/run-sql-tests.sh
#
# Used by CI (.github/workflows/ci.yml). NEVER point it at a real Supabase
# project: it drops and recreates the database named in TEST_DB.
# =============================================================================
set -uo pipefail
: "${PGADMIN_URL:?Set PGADMIN_URL to a superuser connection on a LOCAL Postgres}"
DB="${TEST_DB:-melai_sql_test}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)
TARGET="${PGADMIN_URL%/*}/$DB"

fresh_db() {
  "${PSQL[@]}" "$PGADMIN_URL" -c "drop database if exists $DB with (force)" -c "create database $DB" >/dev/null 2>&1
  "${PSQL[@]}" "$TARGET" -f "$ROOT/supabase/tests/local_supabase_stub.sql" >/dev/null 2>&1
  "${PSQL[@]}" "$TARGET" -f "$ROOT/supabase/schema.sql" >/dev/null 2>&1 || { echo "FAILED: schema.sql"; exit 1; }
  for f in "$ROOT"/supabase/migrations/*.sql; do
    "${PSQL[@]}" "$TARGET" -f "$f" >/dev/null 2>&1 || { echo "FAILED: $f"; "${PSQL[@]}" "$TARGET" -f "$f" 2>&1 | tail -5; exit 1; }
  done
}

fresh_db
PASS=0; FAIL=0; FAILED=()

# 1. A fresh project holds no business data.
if out="$("${PSQL[@]}" "$TARGET" -f "$ROOT/supabase/tests/fresh_install_check.sql" 2>&1)"; then
  PASS=$((PASS+1)); echo "PASS fresh_install_check.sql"
else
  FAIL=$((FAIL+1)); FAILED+=("fresh_install_check.sql"); echo "FAIL fresh_install_check.sql"; printf '%s\n' "$out" | tail -5
fi

# 2. Re-running every migration on a database with real data changes none of it.
"${PSQL[@]}" "$TARGET" >/dev/null 2>&1 <<'SQL'
insert into public.branches (name, address, contact_phone, operating_hours, delivery_fee, daily_sales_target)
  values ('RERUN Branch', 'RERUN street', '0000', 'RERUN hours', 77, 1234);
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
  values ('default', 3, 33, 44);
insert into public.business_settings (id, restock_threshold_default, healthy_margin_percent) values ('default', 7, 33);
update public.payment_settings set online_payment_disabled_message = 'RERUN message' where id = 'default';
SQL
rerun_ok=1
for f in "$ROOT"/supabase/migrations/*.sql; do
  "${PSQL[@]}" "$TARGET" -f "$f" >/dev/null 2>&1 || { rerun_ok=0; echo "  re-run failed: $(basename "$f")"; }
done
check="$("${PSQL[@]}" -At "$TARGET" -c "select
  (select count(*) = 1 from public.branches where name = 'RERUN Branch' and address = 'RERUN street' and contact_phone = '0000'
     and operating_hours = 'RERUN hours' and delivery_fee = 77 and daily_sales_target = 1234)
  and (select points_per_peso = 3 and max_discount_percent = 33 and earn_pesos_per_point = 44 from public.loyalty_cart_settings where id = 'default')
  and (select restock_threshold_default = 7 and healthy_margin_percent = 33 and not carried_over from public.business_settings where id = 'default')
  and (select online_payment_disabled_message = 'RERUN message' from public.payment_settings where id = 'default')" 2>&1)"
if [ "$rerun_ok" = 1 ] && [ "$check" = "t" ]; then PASS=$((PASS+1)); echo "PASS re-running migrations keeps real data"
else FAIL=$((FAIL+1)); FAILED+=("rerun-migrations"); echo "FAIL re-running migrations keeps real data ($check)"; fi
fresh_db
for t in "$ROOT"/supabase/tests/*_test.sql; do
  out="$("${PSQL[@]}" "$TARGET" -f "$t" 2>&1)"; rc=$?
  summary="$(printf '%s\n' "$out" | grep -Ei 'passed|failed' | tail -1)"
  if [ $rc -eq 0 ]; then PASS=$((PASS+1)); echo "PASS $(basename "$t")  $summary"
  else FAIL=$((FAIL+1)); FAILED+=("$(basename "$t")"); echo "FAIL $(basename "$t")"; printf '%s\n' "$out" | tail -15; fi
done
for t in "$ROOT"/supabase/tests/*_test.sh; do
  out="$(DATABASE_URL="$TARGET" bash "$t" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then PASS=$((PASS+1)); echo "PASS $(basename "$t")  $(printf '%s\n' "$out" | tail -1)"
  else FAIL=$((FAIL+1)); FAILED+=("$(basename "$t")"); echo "FAIL $(basename "$t")"; printf '%s\n' "$out" | tail -15; fi
done
echo "SQL suites: $PASS passed, $FAIL failed ${FAILED[*]:-}"
[ $FAIL -eq 0 ]
