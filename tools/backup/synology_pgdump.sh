#!/bin/bash
# Nightly backup of the Supabase database to the NAS (docs/BACKUP.md).
#
#   synology_pgdump.sh <service-file> <backup-folder> [nights-to-keep]
#
#   service-file   root-only (chmod 600) libpq service file with a [rxlab] section: host, port,
#                  dbname, user, password, sslmode of the Session pooler. Never in the repo.
#                  On the NAS: /volume1/@rxlab/pg_service.conf. Its folder is mounted read-only
#                  into the container, so an optional CA certificate can sit next to it
#                  (sslmode=verify-full, sslrootcert=/run/secrets/<file>; docs/BACKUP.md step 3).
#   backup-folder  /volume1/RxLabBackup. Each night writes three files, as `supabase db dump` does:
#                    rxlab_YYYYMMDD-HHMMSS_roles.sql   pg_dumpall --roles-only (custom roles)
#                    rxlab_YYYYMMDD-HHMMSS_schema.sql  pg_dump --schema-only of the app's schemas
#                    rxlab_YYYYMMDD-HHMMSS_data.sql    pg_dump --data-only, incl. auth and storage
#   nights-to-keep default 14: the newest 14 complete nights stay, however old they are (after a
#                  long outage nothing is lost); older nights' three files are deleted together.
#
# Restore (docs/BACKUP.md): psql --single-transaction -f roles -f schema -f data, Supabase's own
# documented command. The flags, excluded schemas and line rewrites are those of the Supabase CLI's
# `db dump` (apps/cli/src/command-internal/pg-dump.env.ts and pg-dump.scripts.ts), plus three
# additions to the schema file so that it restores completely into a new project:
#   - first, CREATE EXTENSION for the extensions in the `extensions` schema (pg_jsonschema), which
#     the CLI leaves to the dashboard;
#   - first, the restoring role's automatic grants are suspended, so every table and function gets
#     exactly the grants it had (pg_dump's ALTER DEFAULT PRIVILEGES lines at the end restore them);
#   - last, the RLS policies this project added to Supabase-managed tables (storage.objects), which
#     the CLI's schema dump does not contain.
#
# Runs pg_dump 17 in the official postgres:17-alpine image (Container Manager). The three files are
# written as .part and renamed together only when all three are complete: a failed or stopped run
# leaves no file, deletes no older backup and exits non-zero (DSM can mail on that). One line per
# run goes to <backup-folder>/backup.log.
#
# Time limits: each pg_dump/pg_dumpall/psql inside the container has DUMP_TIMEOUT (default 1800 s),
# and the whole container RUN_TIMEOUT (default 3600 s); then it is removed and the run fails.
#
# Environment (optional): DOCKER (default /usr/local/bin/docker), IMAGE (default
# postgres:17-alpine), DUMP_TIMEOUT, RUN_TIMEOUT (seconds).
set -u -o pipefail
umask 077

DOCKER="${DOCKER:-/usr/local/bin/docker}"
IMAGE="${IMAGE:-postgres:17-alpine}"
DUMP_TIMEOUT="${DUMP_TIMEOUT:-1800}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3600}"
PREFIX="rxlab"
KINDS="roles schema data"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <service-file> <backup-folder> [nights-to-keep]" >&2
  exit 2
fi
SECRET="$1"
DEST="${2%/}"
KEEP="${3:-14}"
LOG="$DEST/backup.log"
START=$(date +%s)

# The log has no secrets: readable in File Station. The backup files stay 600 (they hold auth.users).
log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG"; chmod 644 "$LOG" 2>/dev/null; }
# Defence in depth: never let a password-looking token reach the log or the DSM mail.
# (Only values: "password authentication failed" must stay readable.)
redact() { sed -E 's#(://[^:/@ ]*:)[^@ ]*@#\1***@#g; s/(password[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1***/Ig'; }
fail() {
  local msg; msg=$(printf '%s' "$*" | redact)
  echo "backup FAILED: $msg" >&2
  [ -d "$DEST" ] && [ -w "$DEST" ] && log "FAIL $msg"
  exit 1
}

# Paths must be absolute: docker -v would read a relative one as a volume name.
case "$SECRET" in /*) ;; *) fail "service file must be an absolute path, got '$SECRET'";; esac
case "$DEST" in /*) ;; *) fail "backup folder must be an absolute path, got '$DEST'";; esac
case "$KEEP" in ''|*[!0-9]*) fail "nights-to-keep must be a number, got '$KEEP'";; esac
[ "$KEEP" -ge 1 ] || fail "nights-to-keep must be at least 1"
[ -d "$DEST" ] && [ -w "$DEST" ] || fail "backup folder $DEST does not exist or is not writable"
[ -f "$SECRET" ] || fail "service file $SECRET not found"
# The service file holds the database password: only its owner (root on the NAS) may read it.
read -r OWNER MODE < <(stat -c '%u %a' "$SECRET") || fail "cannot stat $SECRET"
[ "$OWNER" = "$(id -u)" ] || fail "service file $SECRET must belong to the user running the backup (uid $(id -u)), not uid $OWNER"
case "$MODE" in 600|400) ;; *) fail "service file $SECRET has mode $MODE; run: chmod 600 $SECRET";; esac
grep -q '^[[:space:]]*\[rxlab\][[:space:]]*$' "$SECRET" || fail "service file $SECRET has no [rxlab] section (docs/BACKUP.md step 3)"
[ -x "$DOCKER" ] || fail "docker not found at $DOCKER (install Container Manager)"
SECRET_DIR=$(dirname "$SECRET")
SECRET_NAME=$(basename "$SECRET")

# One run at a time. A lock older than 6 hours is left over from a killed run (a dump takes seconds).
LOCK="$DEST/.backup.lock"
find "$DEST" -maxdepth 1 -name .backup.lock -type d -mmin +360 -exec rmdir {} \; 2>/dev/null
mkdir "$LOCK" 2>/dev/null || fail "another backup is running (remove $LOCK if no backup is running)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="${PREFIX}_${STAMP}"
ERR="$DEST/.backup.err"
CNAME="rxlab-backup-$$"
DPID=""
WATCH=""
cleanup() {
  [ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null
  # Stopped mid-run (Task Scheduler "stop", shutdown): remove the dump container, which ends
  # pg_dump (sh is PID 1 there and would ignore a forwarded SIGTERM).
  if [ -n "$DPID" ]; then
    "$DOCKER" rm -f "$CNAME" > /dev/null 2>&1
    kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
  fi
  rm -f "$DEST/$BASE"_*.sql.part "$ERR"
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT
trap 'log "FAIL stopped by a signal"; exit 143' TERM
trap 'log "FAIL stopped by a signal"; exit 130' INT
# Leftovers of a run that was killed (power cut): never a valid backup.
rm -f "$DEST/${PREFIX}_"*.sql.part

# Runs inside the container. The connection comes from the mounted service file (PGSERVICE), so
# the password is in no command line, environment variable or URI. Schema lists: Supabase CLI.
INNER=$(cat <<'EOS'
# -f: the schema patterns contain * and must reach pg_dump as written. pipefail: a pg_dump that
# fails inside a pipeline fails the run.
set -euf
set -o pipefail
umask 077
OUT="${BACKUP_DIR:-/backup}/$BASE"
INTERNAL='information_schema pg_* _analytics _realtime _supavisor auth etl extensions pgbouncer realtime storage supabase_functions supabase_migrations cron dbdev graphql graphql_public net pgmq pgsodium pgsodium_masks pgtle repack tiger tiger_data timescaledb_* _timescaledb_* topology vault'
DATA_EXCLUDED='information_schema pg_* graphql graphql_public pgsodium pgsodium_masks pgtle repack tiger tiger_data timescaledb_* _timescaledb_* topology vault etl extensions pgbouncer realtime supabase_migrations _analytics _realtime _supavisor'
RESERVED='anon|authenticated|authenticator|cli_login_.*|dashboard_user|pgbouncer|postgres|service_role|supabase_.*|pgsodium_keyholder|pgsodium_keyiduser|pgsodium_keymaker|pgtle_admin'
ALLOWED='pgaudit.*|pgrst.*|session_replication_role|statement_timeout|track_io_timing'
INTERNAL_RE=$(echo "$INTERNAL" | sed 's/\*/.*/g; s/ /|/g')
ex() { for s in $1; do printf -- '--exclude-schema=%s\n' "$s"; done; }
T="timeout -s TERM $DUMP_TIMEOUT"

# 1. Roles (CLI dump_role.sh): custom roles only; Supabase's reserved roles are commented out.
{
  $T pg_dumpall --roles-only --role=postgres --quote-all-identifier --no-role-passwords --no-comments \
  | sed -E 's/^\\(un)?restrict .*$/-- &/' \
  | sed -E "s/^CREATE ROLE \"($RESERVED)\"/-- &/" \
  | sed -E "s/^ALTER ROLE \"($RESERVED)\"/-- &/" \
  | sed -E 's/ (NOSUPERUSER|NOREPLICATION)//g' \
  | sed -E "s/^-- (.* SET \"($ALLOWED)\" .*)/\1/" \
  | sed -E "s/GRANT \".*\" TO \"($RESERVED)\"/-- &/" \
  | sed -E "s/^GRANT [A-Z ,]+ ON PARAMETER \".*\" TO \"($RESERVED)\"([ ;]|\$)/-- &/" \
  | uniq
  echo 'RESET ALL;'
  echo '-- rxlab backup: roles complete'
} > "$OUT"_roles.sql.part

# 2. Schema (CLI dump_schema.sh) with the three additions described in the script header.
{
  echo '-- rxlab backup: extensions the schema uses (a new project has the defaults already)'
  $T psql -X -q -At -v ON_ERROR_STOP=1 -c "set search_path = ''" -c "select format('CREATE EXTENSION IF NOT EXISTS %I WITH SCHEMA %I;', extname, extnamespace::regnamespace) from pg_extension where extnamespace = 'extensions'::regnamespace order by extname"
  echo '-- rxlab backup: no automatic grants while restoring; the dump sets every grant itself'
  echo '-- and ends with the ALTER DEFAULT PRIVILEGES lines that put the automatic ones back.'
  echo 'ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "anon", "authenticated", "service_role";'
  echo 'ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "anon", "authenticated", "service_role";'
  echo 'ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM PUBLIC, "anon", "authenticated", "service_role";'
  # shellcheck disable=SC2046
  $T pg_dump --schema-only --quote-all-identifier --role=postgres $(ex "$INTERNAL") \
  | sed -E 's/^\\(un)?restrict .*$/-- &/' \
  | sed -E 's/^CREATE SCHEMA "/CREATE SCHEMA IF NOT EXISTS "/' \
  | sed -E 's/^CREATE TABLE "/CREATE TABLE IF NOT EXISTS "/' \
  | sed -E 's/^CREATE SEQUENCE "/CREATE SEQUENCE IF NOT EXISTS "/' \
  | sed -E 's/^CREATE VIEW "/CREATE OR REPLACE VIEW "/' \
  | sed -E 's/^CREATE FUNCTION "/CREATE OR REPLACE FUNCTION "/' \
  | sed -E 's/^CREATE TRIGGER "/CREATE OR REPLACE TRIGGER "/' \
  | sed -E 's/^CREATE PUBLICATION "supabase_realtime/-- &/' \
  | sed -E 's/^CREATE EVENT TRIGGER /-- &/' \
  | sed -E 's/^         WHEN TAG IN /-- &/' \
  | sed -E 's/^   EXECUTE FUNCTION /-- &/' \
  | sed -E 's/^ALTER EVENT TRIGGER /-- &/' \
  | sed -E 's/^ALTER PUBLICATION "supabase_realtime_/-- &/' \
  | sed -E 's/^ALTER FOREIGN DATA WRAPPER (.+) OWNER TO /-- &/' \
  | sed -E 's/^ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin"/-- &/' \
  | sed -E 's/^GRANT ALL ON FOREIGN DATA WRAPPER (.+) TO "postgres" WITH GRANT OPTION/-- &/' \
  | sed -E "s/^GRANT (.+) ON (.+) \"($INTERNAL_RE)\"/-- &/" \
  | sed -E "s/^REVOKE (.+) ON (.+) \"($INTERNAL_RE)\"/-- &/" \
  | sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pg_tle").+/\1;/' \
  | sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pgsodium").+/\1;/' \
  | sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pgmq").+/\1;/' \
  | sed -E 's/^COMMENT ON EXTENSION (.+)/-- &/' \
  | sed -E 's/^CREATE POLICY "cron_job_/-- &/' \
  | sed -E 's/^ALTER TABLE "cron"/-- &/' \
  | sed -E 's/^SET transaction_timeout = 0;/-- &/'
  # Read with an empty search_path, as pg_dump does: every function in a policy comes out with its
  # schema, so it restores whatever the restoring session's search_path is.
  echo '-- rxlab backup: RLS policies this project added to Supabase-managed tables'
  $T psql -X -q -At -v ON_ERROR_STOP=1 -c "set search_path = ''" -c "select format(E'DROP POLICY IF EXISTS %I ON %I.%I;\nCREATE POLICY %I ON %I.%I AS %s FOR %s TO %s%s%s;',
      policyname, schemaname, tablename, policyname, schemaname, tablename, permissive, cmd,
      (select string_agg(case when r = 'public' then 'PUBLIC' else quote_ident(r) end, ', ') from unnest(roles) r),
      coalesce(' USING (' || qual || ')', ''), coalesce(' WITH CHECK (' || with_check || ')', ''))
    from pg_policies where schemaname in ('auth', 'storage') order by schemaname, tablename, policyname"
  echo '-- rxlab backup: schema complete'
} > "$OUT"_schema.sql.part

# 3. Data (CLI dump_data.sh, with --use-copy): auth and storage included, platform tables not.
{
  echo 'SET session_replication_role = replica;'
  # shellcheck disable=SC2046
  $T pg_dump --data-only --quote-all-identifier --role=postgres $(ex "$DATA_EXCLUDED") --schema='*' \
     --exclude-table=auth.schema_migrations --exclude-table=storage.migrations \
     --exclude-table=supabase_functions.migrations \
  | sed -E 's/^\\(un)?restrict .*$/-- &/'
  echo 'RESET ALL;'
  echo '-- rxlab backup: data complete'
} > "$OUT"_data.sql.part
EOS
)

# No --init: DSM's Docker may lack docker-init. A stop removes the container (cleanup).
# Hardening that cannot get in the way of writing to the share: no privilege gain, read-only root
# file system (pg_dump writes only to /backup), bridge network. Capabilities are left as they are:
# root writing into a Synology ACL share was not tested without them.
"$DOCKER" run --rm --name "$CNAME" \
  --security-opt no-new-privileges --read-only --tmpfs /tmp --network bridge \
  -v "$SECRET_DIR:/run/secrets:ro" \
  -v "$DEST:/backup" \
  -e PGSERVICEFILE="/run/secrets/$SECRET_NAME" \
  -e PGSERVICE=rxlab \
  -e PGCONNECT_TIMEOUT=30 \
  -e PGAPPNAME=nas-backup \
  -e BASE="$BASE" \
  -e DUMP_TIMEOUT="$DUMP_TIMEOUT" \
  "$IMAGE" sh -c "$INNER" > /dev/null 2> "$ERR" &
# In the background and waited for, so a stop signal is handled at once (bash runs traps only
# between commands, and `wait` is interruptible).
DPID=$!
# Watchdog for the whole run: a stalled connection cannot hold the lock until the next night.
# Its sleep runs in the background and is killed with it (a stopped watchdog must not leave a
# sleeping child behind, holding the task's output open).
(
  trap 'kill "$SP" 2>/dev/null; exit 0' TERM
  sleep "$RUN_TIMEOUT" & SP=$!
  wait "$SP" && "$DOCKER" rm -f "$CNAME"
) < /dev/null > /dev/null 2>&1 &
WATCH=$!
wait "$DPID"
RC=$?
DPID=""
kill "$WATCH" 2>/dev/null; wait "$WATCH" 2>/dev/null; WATCH=""

if [ "$RC" -ne 0 ] && [ $(( $(date +%s) - START )) -ge "$RUN_TIMEOUT" ]; then
  fail "the dump took longer than $RUN_TIMEOUT s and was stopped (network or Supabase stalled)"
fi
if [ "$RC" -ne 0 ]; then
  MSG=$(head -c 400 "$ERR" 2>/dev/null | tr '\n' ' ')
  fail "dump exit $RC: ${MSG:-no output}"
fi
# Each file must end with its completion line: a cut-off file is not a backup.
for k in $KINDS; do
  f="$DEST/${BASE}_$k.sql.part"
  [ -s "$f" ] && tail -n 1 "$f" | grep -qx -- "-- rxlab backup: $k complete" \
    || fail "the $k file is incomplete"
done
for k in $KINDS; do
  mv -f "$DEST/${BASE}_$k.sql.part" "$DEST/${BASE}_$k.sql" || fail "could not rename the $k file"
  chmod 600 "$DEST/${BASE}_$k.sql"
done
# One time stamp for the night's three files (after all three are renamed): the cleanup keeps or
# deletes them together.
touch -r "$DEST/${BASE}_data.sql" "$DEST/${BASE}_roles.sql" "$DEST/${BASE}_schema.sql" \
  || fail "could not set the files' time stamp"
BYTES=$(cat "$DEST/${BASE}"_*.sql | wc -c)

# Retention only after a good night, by count: the newest KEEP nights stay (newest by time stamp,
# a night is its data file), however old they are. Every other night's files go, all three
# together; keep_ sets and other files are never touched.
DELETED=0
NIGHTS=0
OLDEST_KEPT=""
for f in $(ls -1t "$DEST/${PREFIX}_"*_data.sql 2>/dev/null); do
  NIGHTS=$((NIGHTS + 1))
  if [ "$NIGHTS" -le "$KEEP" ]; then OLDEST_KEPT="$f"; continue; fi
  stamp=$(basename "$f" _data.sql)
  for k in $KINDS; do
    [ -f "$DEST/${stamp}_$k.sql" ] && rm -f "$DEST/${stamp}_$k.sql" && DELETED=$((DELETED + 1))
  done
done
[ "$NIGHTS" -gt "$KEEP" ] && NIGHTS=$KEEP
# Roles or schema files whose night has no data file and is older than every kept night.
if [ -n "$OLDEST_KEPT" ]; then
  ORPHANS=$(find "$DEST" -maxdepth 1 -type f \( -name "${PREFIX}_*_roles.sql" -o -name "${PREFIX}_*_schema.sql" \) ! -newer "$OLDEST_KEPT" -print)
  for f in $ORPHANS; do
    s="${f%_*.sql}"
    [ -f "${s}_data.sql" ] || { rm -f "$f" && DELETED=$((DELETED + 1)); }
  done
fi

log "OK $BASE (roles, schema, data) $BYTES bytes $(( $(date +%s) - START ))s, deleted $DELETED old files, $NIGHTS nights kept"
echo "backup OK: $DEST/${BASE}_{roles,schema,data}.sql ($BYTES bytes)"
exit 0
