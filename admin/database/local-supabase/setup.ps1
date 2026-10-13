# =============================================================================
# Windows version of setup.sh: creates a LOCAL copy of the Melai Nuts Supabase database
# (schema + every migration + sample data) on a local PostgreSQL. Development only.
#
# Needs PostgreSQL 15+ installed locally (https://www.postgresql.org/download/windows/,
# or Laragon's PostgreSQL) with psql.exe on PATH. From the repository root:
#
#   $env:PGADMIN_URL = "postgresql://postgres:YOURPW@127.0.0.1:5432/postgres"
#   powershell -ExecutionPolicy Bypass -File admin\database\local-supabase\setup.ps1
#
# Re-running DROPS and recreates the local database melai_local. It never touches Supabase.
# =============================================================================
$ErrorActionPreference = 'Stop'
if (-not $env:PGADMIN_URL) { throw 'Set $env:PGADMIN_URL to a superuser connection on a LOCAL Postgres.' }
if ($env:PGADMIN_URL -match 'supabase') { throw 'Refusing: PGADMIN_URL points at Supabase. Use a LOCAL Postgres.' }
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { throw 'psql.exe not found. Add PostgreSQL\<version>\bin to PATH.' }

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$admin = Resolve-Path (Join-Path $here '..\..')
$root  = Resolve-Path (Join-Path $admin '..')
$db    = if ($env:LOCAL_DB) { $env:LOCAL_DB } else { 'melai_local' }
$base  = $env:PGADMIN_URL.Substring(0, $env:PGADMIN_URL.LastIndexOf('/'))
$target = "$base/$db"

function EnvVal($name) {
  $line = Get-Content (Join-Path $admin '.env') -ErrorAction SilentlyContinue | Where-Object { $_ -match "^$name=" } | Select-Object -Last 1
  if ($line) { return ($line -replace "^$name=", '').Trim('"') } else { return '' }
}
$ownerUid   = if ($env:OWNER_UID) { $env:OWNER_UID } elseif (EnvVal 'ADMIN_STAFF_UID') { EnvVal 'ADMIN_STAFF_UID' } else { 'local-owner' }
$ownerEmail = if ($env:OWNER_EMAIL) { $env:OWNER_EMAIL } elseif (EnvVal 'ADMIN_EMAIL') { EnvVal 'ADMIN_EMAIL' } else { 'owner@melai.local' }

function Psql([string[]]$a) { & psql -X -q -v ON_ERROR_STOP=1 @a; if ($LASTEXITCODE -ne 0) { throw "psql failed: $a" } }

Psql @($env:PGADMIN_URL, '-c', "drop database if exists $db with (force)", '-c', "create database $db")
Psql @($target, '-f', (Join-Path $root 'supabase\tests\local_supabase_stub.sql')) 2>$null
Psql @($target, '-f', (Join-Path $root 'supabase\schema.sql')) *> $null
Get-ChildItem (Join-Path $root 'supabase\migrations\*.sql') | Sort-Object Name | ForEach-Object {
  & psql -X -q -v ON_ERROR_STOP=1 $target -f $_.FullName *> $null
  if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: $($_.Name)"; & psql -X -v ON_ERROR_STOP=1 $target -f $_.FullName | Select-Object -Last 5; exit 1 }
}
Psql @($target, '-c', "alter role melai_admin_portal with login password 'portal-test-pw'")
Psql @('-v', "owner_uid=$ownerUid", '-v', "owner_email=$ownerEmail", $target, '-f', (Join-Path $here 'seed.sql'))
Write-Host "Local database $db is ready (owner: $ownerEmail / $ownerUid)."
Write-Host 'Website DB login: melai_admin_portal / portal-test-pw (local only).'
