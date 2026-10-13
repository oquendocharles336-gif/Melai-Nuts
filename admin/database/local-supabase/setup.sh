#!/usr/bin/env bash
# =============================================================================
# Creates a LOCAL copy of the Melai Nuts Supabase database (schema + every migration + sample data)
# so the admin website runs fast on your machine (no internet round trips). Development only.
#
#   PGADMIN_URL=postgresql://postgres:YOURPW@127.0.0.1:5432/postgres bash admin/database/local-supabase/setup.sh
#
# Then switch admin/.env to it (see "LOCAL Supabase copy" in admin/.env.example) and run
#   php artisan optimize:clear && php artisan cache:clear
# Re-running DROPS and recreates the local database melai_local. It never touches Supabase.
# =============================================================================
set -euo pipefail
: "${PGADMIN_URL:?Set PGADMIN_URL to a superuser connection on a LOCAL Postgres}"
case "$PGADMIN_URL" in *supabase*) echo "Refusing: PGADMIN_URL points at Supabase. Use a LOCAL Postgres." >&2; exit 1;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
ADMIN="$(cd "$HERE/../.." && pwd)"
DB="${LOCAL_DB:-melai_local}"

# Your owner identity from admin/.env, so your usual sign-in works against the local copy.
envval() { grep -E "^$1=" "$ADMIN/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"//;s/"$//'; }
OWNER_UID="${OWNER_UID:-$(envval ADMIN_STAFF_UID)}"; OWNER_UID="${OWNER_UID:-local-owner}"
OWNER_EMAIL="${OWNER_EMAIL:-$(envval ADMIN_EMAIL)}"; OWNER_EMAIL="${OWNER_EMAIL:-owner@melai.local}"

PGADMIN_URL="$PGADMIN_URL" TEST_DB="$DB" bash "$ADMIN/tests/Supabase/prepare-test-db.sh"
psql -X -q -v ON_ERROR_STOP=1 -v owner_uid="$OWNER_UID" -v owner_email="$OWNER_EMAIL" "${PGADMIN_URL%/*}/$DB" -f "$HERE/seed.sql"
echo "Local database $DB is ready (owner: $OWNER_EMAIL / $OWNER_UID)."
echo "Website DB login: melai_admin_portal / portal-test-pw (local only)."
