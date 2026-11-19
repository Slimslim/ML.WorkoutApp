#!/bin/bash
# Monthly restore test (docs/BACKUP.md step 7): loads one night's three files (roles, schema,
# data) into a throwaway postgres container on the NAS, checks that every table got exactly the
# rows of the backup, then removes the container. Nothing leaves the NAS; the database lives in
# memory (tmpfs) and is deleted with the container.
#
#   synology_restore_test.sh <backup-folder> [night]
#
#   night  default: the newest night. Either its time stamp (20261120-030001) or the name the
#          three files start with (keep_rxlab_20261120-031500 for a kept pre-change backup).
#
# Environment (optional): DOCKER (default /usr/local/bin/docker), IMAGE (default postgres:17-alpine).
#
# A plain postgres is not Supabase: it has none of Supabase's roles, no auth or storage tables and
# no pg_jsonschema. The test creates empty stand-ins first (the API roles, auth.uid(),
# storage.foldername(), a jsonb_matches_schema that accepts every row, and auth/storage tables
# with the columns the backup's data file lists). It proves the files are complete and load; the
# full restore into Supabase itself is docs/BACKUP.md step 9.
# Exit 0: every table has exactly its rows and no unexpected error. Exit 1 otherwise.
set -u -o pipefail
umask 077

DOCKER="${DOCKER:-/usr/local/bin/docker}"
IMAGE="${IMAGE:-postgres:17-alpine}"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: $0 <backup-folder> [night]" >&2; exit 2; }
DIR="${1%/}"
case "$DIR" in /*) ;; *) DIR="$(pwd)/$DIR";; esac
if [ "$#" -eq 2 ]; then
  case "$2" in *rxlab_*) BASE="$2";; *) BASE="rxlab_$2";; esac
else
  NEWEST=$(ls -t "$DIR"/rxlab_*_data.sql 2> /dev/null | head -n 1)
  [ -n "$NEWEST" ] || { echo "no backup found in $DIR" >&2; exit 2; }
  BASE=$(basename "$NEWEST" _data.sql)
fi
for k in roles schema data; do
  [ -s "$DIR/${BASE}_$k.sql" ] || { echo "missing $DIR/${BASE}_$k.sql" >&2; exit 2; }
  # The backup ends every file with this line: a file cut off part-way is not a backup.
  tail -n 1 "$DIR/${BASE}_$k.sql" | grep -qx -- "-- rxlab backup: $k complete" \
    || { echo "restore test FAILED: ${BASE}_$k.sql is incomplete" >&2; exit 1; }
done

NAME="rxlab-restore-test-$$"
WORK=$(mktemp -d) || exit 1
cleanup() { "$DOCKER" rm -fv "$NAME" > /dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# The data file's COPY lines name every table and its columns: the stand-ins for Supabase's own
# auth and storage tables are made from them (text columns; auth.users.id is the uuid key the
# app's tables reference). Rows per table in the backup, for the comparison at the end.
awk '
  /^COPY "(auth|storage)"\./ {
    split($2, q, "\""); s = q[2]; t = q[4]
    cols = $0; sub(/^COPY [^(]*\(/, "", cols); sub(/\) FROM stdin;$/, "", cols)
    n = split(cols, c, ", ")
    printf "CREATE TABLE IF NOT EXISTS \"%s\".\"%s\" (", s, t
    for (i = 1; i <= n; i++) {
      type = (s == "auth" && t == "users" && c[i] == "\"id\"") ? "uuid PRIMARY KEY" : "text"
      printf "%s%s %s", (i > 1 ? ", " : ""), c[i], type
    }
    print ");"
  }' "$DIR/${BASE}_data.sql" > "$WORK/standin_tables.sql"
awk '
  /^COPY / { t = $2; n = 0; inblk = 1; next }
  inblk && $0 == "\\." { print t, n; inblk = 0; next }
  inblk { n++ }' "$DIR/${BASE}_data.sql" > "$WORK/expected"
[ -s "$WORK/expected" ] || { echo "restore test FAILED: the data file holds no table data" >&2; exit 1; }

# A random password only for this throwaway container; it opens no port on the NAS.
"$DOCKER" run -d --name "$NAME" --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_PASSWORD="restore-test-$RANDOM$RANDOM" \
  -v "$DIR:/restore:ro" -v "$WORK:/work:ro" "$IMAGE" > /dev/null \
  || { echo "could not start $IMAGE" >&2; exit 1; }
for _ in $(seq 1 60); do
  "$DOCKER" exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -q 2> /dev/null && break
  sleep 1
done
"$DOCKER" exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -q || { echo "test database did not start" >&2; exit 1; }

cat > "$WORK/standins.sql" <<'SQL'
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
create schema extensions;
create schema auth;
create schema storage;
create function extensions.jsonb_matches_schema(schema json, instance jsonb) returns boolean
  language sql immutable as 'select true';
create function extensions.json_matches_schema(schema json, instance json) returns boolean
  language sql immutable as 'select true';
create function auth.uid() returns uuid language sql stable
  as $f$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
create function auth.role() returns text language sql stable
  as $f$ select nullif(current_setting('request.jwt.claim.role', true), '') $f$;
create function storage.foldername(name text) returns text[] language sql immutable
  as $f$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $f$;
SQL
chmod 644 "$WORK"/*.sql; chmod 755 "$WORK"

psqlc() { "$DOCKER" exec "$NAME" psql -U postgres -X -q "$@"; }
psqlc -v ON_ERROR_STOP=1 -f /work/standins.sql -f /work/standin_tables.sql > /dev/null \
  || { echo "could not prepare the test database" >&2; exit 1; }

echo "restoring $BASE (roles, schema, data) ..."
# Not one transaction here: what a plain postgres lacks (pg_jsonschema) fails on its own line and
# is reported, and everything else still loads. Expected misses are filtered out below.
psqlc -f "/restore/${BASE}_roles.sql" -f "/restore/${BASE}_schema.sql" -f "/restore/${BASE}_data.sql" \
  > /dev/null 2> "$WORK/errors"
# Supabase-only objects: present in a Supabase project (step 9 restores them), not in plain postgres.
SUPABASE_ONLY='extension "[^"]+" is not available|publication "supabase_realtime[^"]*" does not exist|relation "(auth|storage)\.[^"]+_seq" does not exist|already exists'
grep -E 'ERROR' "$WORK/errors" | grep -E "$SUPABASE_ONLY" | sed -E 's/^psql:[^ ]+ ERROR: +/  Supabase-only, skipped: /' | sort -u
UNEXPECTED=$(grep -E 'ERROR' "$WORK/errors" | grep -v -E "$SUPABASE_ONLY" || true)
if [ -n "$UNEXPECTED" ]; then
  echo "unexpected errors while loading:"
  # Only where (file:line), not the message: an error can quote a row (an email), and a
  # scheduled run mails this output.
  echo "$UNEXPECTED" | head -20 | sed -E 's/^psql:([^ ]+): ERROR:.*/  \1/'
fi

BAD=0
printf '%-48s %9s %9s\n' table backup restored
while read -r TABLE WANT; do
  GOT=$("$DOCKER" exec "$NAME" psql -U postgres -X -At -c "select count(*) from $TABLE" < /dev/null 2> /dev/null || echo missing)
  MARK=""
  [ "$GOT" = "$WANT" ] || { MARK="  <-- MISMATCH"; BAD=1; }
  printf '%-48s %9s %9s%s\n' "$TABLE" "$WANT" "$GOT" "$MARK"
done < "$WORK/expected"
TABLES=$(wc -l < "$WORK/expected")

if [ "$BAD" -ne 0 ]; then echo "restore test FAILED: some tables are missing rows" >&2; exit 1; fi
if [ -n "$UNEXPECTED" ]; then echo "restore test FAILED: unexpected errors (above)" >&2; exit 1; fi
echo "restore test OK: $BASE, $TABLES tables, every row restored"
