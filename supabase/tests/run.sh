#!/usr/bin/env bash
# SQL tests for the Supabase migrations, on a throwaway supabase/postgres database (it has the
# auth schema, the API roles and pg_jsonschema). Never point this at the live project.
#
#   docker run -d --name barpath-pg -e POSTGRES_PASSWORD=postgres -p 54322:5432 supabase/postgres:15.8.1.085
#   PGURL=postgres://postgres:postgres@localhost:54322/postgres supabase/tests/run.sh
#
# Order: migrations before 20261118 -> a synthetic production-like seed (29 published rows,
# 2,518 drafts) -> the new migrations -> checks -> make_row.py output for the v2 fixtures ->
# checks -> the rollback script -> checks. Needs a fresh database each run (CI starts a new container).
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${PGURL:?set PGURL to a throwaway supabase/postgres database}"
case "$PGURL" in *supabase.co*|*supabase.com*) echo "refusing to run against a hosted project" >&2; exit 2;; esac

psql_run() { psql "$PGURL" -X -q -o /dev/null -v ON_ERROR_STOP=1 "$@" 2>&1 | sed -e 's/^psql:[^ ]* NOTICE:  /  /'; return "${PIPESTATUS[0]}"; }
NEW_FROM=20261118000000

# The image runs its init scripts after the server first accepts connections: wait for them.
for i in $(seq 1 60); do
  if psql "$PGURL" -X -q -At -c "select 1 from pg_available_extensions where name = 'pg_jsonschema'" 2>/dev/null | grep -q 1 \
     && psql "$PGURL" -X -q -At -c "select to_regprocedure('auth.uid()') is not null" 2>/dev/null | grep -q t; then
    break
  fi
  [ "$i" -lt 60 ] || { echo "database not ready" >&2; exit 1; }
  sleep 2
done

psql_run -f supabase/tests/00_harness.sql
for f in supabase/migrations/*.sql; do
  ts=$(basename "$f" | cut -d_ -f1)
  [ "$ts" -lt "$NEW_FROM" ] || continue
  case "$f" in
    *_uploads.sql) echo "skip $f (Storage tables come from the Storage service, not this image)"; continue;;
  esac
  echo "migrate $f"; psql_run -f "$f"
done

echo "seed"; psql_run -f supabase/tests/10_seed_production_like.sql

for f in supabase/migrations/*.sql; do
  ts=$(basename "$f" | cut -d_ -f1)
  [ "$ts" -ge "$NEW_FROM" ] || continue
  echo "migrate $f"; psql_run -f "$f"
done

echo "tests: drafts"; psql_run -f supabase/tests/20_drafts_moved.sql

# The database refuses every invalid fixture and accepts every valid one (same files as the
# Python tests, so the two validators agree).
for f in tools/library/fixtures/v2/valid/*.json tools/library/fixtures/v2/invalid/*.json; do
  want=t; case "$f" in */invalid/*) want=f;; esac
  doc=$(cat "$f")
  got=$(printf '%s\n' "select extensions.jsonb_matches_schema(public.workout_definition_v2_schema(), coalesce((:'doc'::jsonb) -> 'definition', :'doc'::jsonb));" \
        | psql "$PGURL" -X -q -At -v ON_ERROR_STOP=1 -v doc="$doc")
  if [ "$got" != "$want" ]; then echo "FAILED: schema check of $f gave $got, expected $want" >&2; exit 1; fi
  echo "ok - schema: $(basename "$f") -> $got"
done

echo "make_row: v2 fixtures"
python3 tools/library/make_row.py tools/library/fixtures/v2/valid/*.json | psql_run
echo "make_row: the same SQL again (an update of existing rows, exact ones with copies)"
python3 tools/library/make_row.py tools/library/fixtures/v2/valid/*.json | psql_run

echo "tests: v2"; psql_run -f supabase/tests/30_v2.sql

# The rollback script works and restores the library exactly. The delete-account test above
# removed the tester's fixture rows only (not part of the snapshot).
echo "rollback"; psql_run -f supabase/rollback/20261118_backend_v2_rollback.sql
echo "tests: after rollback"; psql_run -f supabase/tests/40_after_rollback.sql
echo "all SQL tests passed"
