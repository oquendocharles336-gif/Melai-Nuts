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
