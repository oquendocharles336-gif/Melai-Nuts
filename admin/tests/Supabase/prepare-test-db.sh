#!/usr/bin/env bash
# =============================================================================
# Builds a throwaway local Postgres database that looks like the Melai Nuts
# Supabase project (stub roles + schema.sql + every migration), for the
# admin portal's Supabase integration tests (tests/Feature/SupabaseIntegrationTest.php).
#
#   PGADMIN_URL=postgresql://postgres@127.0.0.1:5432/postgres \
#     bash admin/tests/Supabase/prepare-test-db.sh
#
# Then run, from admin/:
#   SUPABASE_TEST_ADMIN_URL=postgresql://postgres@127.0.0.1:5432/melai_portal_test \
#   SUPABASE_TEST_PORTAL_URL=postgresql://melai_admin_portal:portal-test-pw@127.0.0.1:5432/melai_portal_test \
#     php artisan test --group=supabase
#
# NEVER point this at a real Supabase project: it drops and recreates the database.
# =============================================================================
set -euo pipefail
: "${PGADMIN_URL:?Set PGADMIN_URL to a superuser connection on a LOCAL Postgres}"
DB="${TEST_DB:-melai_portal_test}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # repository root
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" "$PGADMIN_URL" -c "drop database if exists $DB with (force)" -c "create database $DB"
TARGET="${PGADMIN_URL%/*}/$DB"
"${PSQL[@]}" "$TARGET" -f "$ROOT/supabase/tests/local_supabase_stub.sql" 2>/dev/null
"${PSQL[@]}" "$TARGET" -f "$ROOT/supabase/schema.sql" >/dev/null 2>&1
for f in "$ROOT"/supabase/migrations/*.sql; do
  "${PSQL[@]}" "$TARGET" -f "$f" >/dev/null 2>&1 || { echo "FAILED: $f"; "${PSQL[@]}" "$TARGET" -f "$f" | tail -5; exit 1; }
done
"${PSQL[@]}" "$TARGET" -c "alter role melai_admin_portal with login password 'portal-test-pw'"
echo "Test database $DB is ready."
