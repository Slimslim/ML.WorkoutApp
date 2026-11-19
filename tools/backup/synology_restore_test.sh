#!/bin/bash
# Monthly restore test (docs/BACKUP.md): restores a dump into a throwaway postgres container on the
# NAS, compares every table's row count with the rows in the dump, then removes the container.
# Nothing is sent anywhere; the database lives in memory (tmpfs) and is gone afterwards.
#
#   synology_restore_test.sh <dump-file>        e.g. the newest /volume1/Backups/rxlab/rxlab_*.dump
#
# Environment (optional): DOCKER (default /usr/local/bin/docker), IMAGE (default postgres:17-alpine).
#
# A plain postgres has none of Supabase's roles and extensions, so the test first creates empty
# stand-ins: the API roles (policies name them) and extensions.jsonb_matches_schema (the v2 table's
# check constraint calls it; the stand-in accepts every row, which is fine for counting rows).
# Exit 0: every table has exactly the rows of the dump. Exit 1: a table is missing rows.
set -u -o pipefail

DOCKER="${DOCKER:-/usr/local/bin/docker}"
IMAGE="${IMAGE:-postgres:17-alpine}"
[ "$#" -eq 1 ] || { echo "usage: $0 <dump-file>" >&2; exit 2; }
DUMP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
[ -s "$DUMP" ] || { echo "dump $DUMP not found or empty" >&2; exit 2; }
NAME="rxlab-restore-test-$$"

cleanup() { "$DOCKER" rm -f "$NAME" > /dev/null 2>&1; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# A random password only for this throwaway container; it listens on no host port.
"$DOCKER" run -d --name "$NAME" --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_PASSWORD="restore-test-$RANDOM$RANDOM" \
  -v "$DUMP:/restore/backup.dump:ro" "$IMAGE" > /dev/null || { echo "could not start $IMAGE" >&2; exit 1; }

in_db() { "$DOCKER" exec -i "$NAME" "$@"; }
for _ in $(seq 1 60); do
  in_db pg_isready -U postgres -h 127.0.0.1 -q 2> /dev/null && break
  sleep 1
done
in_db pg_isready -U postgres -h 127.0.0.1 -q || { echo "test database did not start" >&2; exit 1; }

in_db psql -U postgres -X -q -v ON_ERROR_STOP=1 <<'SQL' || { echo "could not prepare the test database" >&2; exit 1; }
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'authenticator', 'supabase_admin',
                           'supabase_auth_admin', 'supabase_storage_admin', 'dashboard_user'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
end $$;
create schema if not exists extensions;
create function extensions.jsonb_matches_schema(schema json, instance jsonb) returns boolean
  language sql immutable as 'select true';
create function extensions.json_matches_schema(schema json, instance json) returns boolean
  language sql immutable as 'select true';
SQL

echo "restoring $(basename "$DUMP") ..."
# No --exit-on-error: Supabase-only objects a plain postgres lacks (event triggers, some
# extensions) fail and are listed; what counts is that every table gets all of its rows.
in_db pg_restore -U postgres -d postgres --no-owner --no-acl /restore/backup.dump > /tmp/rxlab-restore.$$ 2>&1
# (The plain image already has a public schema: that one is expected.)
grep -E '^pg_restore: error' /tmp/rxlab-restore.$$ | grep -v 'schema "public" already exists' | sed 's/^/  skipped: /' | head -20
rm -f /tmp/rxlab-restore.$$

# Rows per table in the dump itself (COPY blocks), against rows per table after the restore.
in_db sh -c 'pg_restore --data-only -f - /restore/backup.dump' | awk '
  /^COPY / { t = $2; n = 0; inblk = 1; next }
  inblk && $0 == "\\." { print t, n; inblk = 0; next }
  inblk { n++ }' > /tmp/rxlab-expected.$$

BAD=0
printf '%-45s %10s %10s\n' table dump restored
while read -r TABLE WANT; do
  # No -i here: docker exec would read the rest of the table list from this loop's input.
  GOT=$("$DOCKER" exec "$NAME" psql -U postgres -X -At -c "select count(*) from $TABLE" < /dev/null 2> /dev/null || echo missing)
  MARK=""
  [ "$GOT" = "$WANT" ] || { MARK="  <-- MISMATCH"; BAD=1; }
  printf '%-45s %10s %10s%s\n' "$TABLE" "$WANT" "$GOT" "$MARK"
done < /tmp/rxlab-expected.$$
TABLES=$(wc -l < /tmp/rxlab-expected.$$)
rm -f /tmp/rxlab-expected.$$

if [ "$TABLES" -eq 0 ]; then echo "restore test FAILED: the dump holds no table data" >&2; exit 1; fi
if [ "$BAD" -ne 0 ]; then echo "restore test FAILED: some tables are missing rows" >&2; exit 1; fi
echo "restore test OK: $TABLES tables, every row restored"
