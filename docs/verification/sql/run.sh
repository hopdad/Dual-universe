#!/usr/bin/env bash
# Reproduces the schema verification in docs/verification.md.
#
# Needs a scratch PostgreSQL 16 server and a superuser connection through the
# usual libpq variables (PGHOST, PGPORT, PGUSER). It creates two throwaway
# databases, applies the handoff migrations 0001-0003 (plus 0005_fixes.sql in
# the second one) on top of a small Supabase stand-in, and prints the scenario
# results. pg_cron is not needed: 0004_retention.sql is not exercised here.
#
# Example with a disposable cluster (run as a non-root user, or via runuser):
#   initdb -D /tmp/pgv -A trust -U postgres
#   pg_ctl -D /tmp/pgv -o "-p 55432 -k /tmp" start
#   PGHOST=/tmp PGPORT=55432 PGUSER=postgres ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=error"

run_suite() {
  local db=$1 tests=$2
  shift 2
  psql -X -q -d postgres -c "drop database if exists $db" -c "create database $db" >/dev/null
  for f in "$@"; do
    psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$f" >/dev/null
  done
  echo "=== $tests on $db"
  psql -X -d "$db" -f "$tests" 2>&1 | sed -E 's/^psql:[^:]+:[0-9]+: //'
}

run_suite dufleet_verify_handoff tests_handoff.sql \
  00_supabase_stub.sql 0001_core.sql 0002_rls.sql 0003_realtime.sql
run_suite dufleet_verify_fixed tests_fixed.sql \
  00_supabase_stub.sql 0001_core.sql 0002_rls.sql 0003_realtime.sql 0005_fixes.sql
