#!/usr/bin/env bash
# Applies supabase/migrations and supabase/seed to a scratch database on plain
# PostgreSQL, on top of a small Supabase stand-in (00_platform_stub.sql), and runs
# scenarios.sql. Exits non-zero at the first failed check.
#
# Needs PostgreSQL 15 or later and a superuser connection through the usual libpq
# variables (PGHOST, PGPORT, PGUSER). The database name defaults to dufleet_hub_test.
# A disposable cluster, for example:
#   initdb -D /tmp/pgh -A trust -U postgres && pg_ctl -D /tmp/pgh -o "-p 55433 -k /tmp" start
#   PGHOST=/tmp PGPORT=55433 PGUSER=postgres supabase/tests/run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
db=${DUFLEET_TEST_DB:-dufleet_hub_test}
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"

psql -X -q -d postgres -c "drop database if exists $db" -c "create database $db template template0 encoding 'UTF8'"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$here/00_platform_stub.sql"
for f in "$here"/../migrations/*.sql "$here"/../seed/*.sql; do
  psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$f"
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$here/scenarios.sql"
