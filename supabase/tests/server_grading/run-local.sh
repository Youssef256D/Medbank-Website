#!/usr/bin/env bash
# Runs the server-side grading migration and its rollback against a throwaway
# local Postgres (needs `initdb`/`pg_ctl`/`psql` on PATH). Never touches the
# hosted project.
#   bash supabase/tests/server_grading/run-local.sh
set -euo pipefail
export LC_ALL=C LANG=C

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
migration="$repo/supabase/migrations/20261027125000_server_side_grading.sql"
rollback="$repo/supabase/rollbacks/20261027125000_server_side_grading.down.sql"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/medbank-grading.XXXXXX")"
port=55439

cleanup() {
  pg_ctl -D "$tmp/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

initdb -D "$tmp/data" -U postgres -A trust --locale=C -E UTF8 >/dev/null
pg_ctl -D "$tmp/data" -o "-p $port -k '' -c listen_addresses=127.0.0.1" -l "$tmp/log" -w start >/dev/null

run() { psql -h 127.0.0.1 -p "$port" -U postgres -v ON_ERROR_STOP=1 -q -o /dev/null "$@"; }

run -d postgres -c "create database grading"
run -d grading -f "$here/stubs.sql"
run -d grading -f "$migration"
run -d grading -f "$here/test.sql"
run -d grading -f "$rollback"
run -d grading -f "$here/rollback-check.sql"
echo "migration, checks and rollback OK"
