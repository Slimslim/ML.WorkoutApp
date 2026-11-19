#!/bin/bash
# Nightly backup of the Supabase database to the NAS (docs/BACKUP.md).
#
#   synology_pgdump.sh <connection-file> <backup-folder> [days-to-keep]
#
#   connection-file  a root-only file (chmod 600) holding one line: the Session pooler connection
#                    string, postgresql://USER:PASSWORD@HOST:5432/postgres. Never in the repo.
#   backup-folder    e.g. /volume1/Backups/rxlab. Dumps are written as rxlab_YYYYMMDD-HHMMSS.dump.
#   days-to-keep     default 14: one dump per night, the 14 newest stay.
#
# Runs pg_dump in the official postgres:17-alpine image (Container Manager), so nothing is
# installed on the NAS. The dump is written to a .part file and renamed only after pg_dump
# succeeded and pg_restore can read it back: a failed run leaves no file, exits non-zero (DSM
# Task Scheduler can mail on that) and deletes no older dump. One line per run goes to
# <backup-folder>/backup.log.
#
# What is dumped (docs/BACKUP.md, "What the dump contains"): the schemas public, auth and storage,
# schema and data, in pg_dump's custom format. Not Supabase's internal schemas (restoring those
# into a Supabase project fails), and not the data of the tables Supabase's services manage
# themselves (auth.schema_migrations, storage.migrations).
#
# Environment (optional): DOCKER (default /usr/local/bin/docker), IMAGE (default
# postgres:17-alpine), PGSSLMODE (default require; tests against a local container set disable).
set -u -o pipefail
umask 077

DOCKER="${DOCKER:-/usr/local/bin/docker}"
IMAGE="${IMAGE:-postgres:17-alpine}"
SSLMODE="${PGSSLMODE:-require}"
PREFIX="rxlab"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <connection-file> <backup-folder> [days-to-keep]" >&2
  exit 2
fi
SECRET="$1"
DEST="${2%/}"
KEEP="${3:-14}"
LOG="$DEST/backup.log"
START=$(date +%s)

# The log has no secrets (pg_dump never prints the password): readable in File Station. The dumps
# stay 600, they hold auth.users.
log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG"; chmod 644 "$LOG" 2>/dev/null; }
fail() {
  # Before the folder is known to be writable, the message only goes to stderr.
  echo "backup FAILED: $*" >&2
  [ -w "$DEST" ] && log "FAIL $*"
  exit 1
}

case "$KEEP" in ''|*[!0-9]*) fail "days-to-keep must be a number, got '$KEEP'";; esac
[ "$KEEP" -ge 1 ] || fail "days-to-keep must be at least 1"
[ -d "$DEST" ] && [ -w "$DEST" ] || fail "backup folder $DEST does not exist or is not writable"
[ -f "$SECRET" ] || fail "connection file $SECRET not found"
# The connection file holds the database password: only its owner (root on the NAS) may read it.
read -r OWNER MODE < <(stat -c '%u %a' "$SECRET") || fail "cannot stat $SECRET"
[ "$OWNER" = "$(id -u)" ] || fail "connection file $SECRET must belong to the user running the backup (uid $(id -u)), not uid $OWNER"
case "$MODE" in 600|400) ;; *) fail "connection file $SECRET has mode $MODE; run: chmod 600 $SECRET";; esac
[ -s "$SECRET" ] || fail "connection file $SECRET is empty"
[ -x "$DOCKER" ] || fail "docker not found at $DOCKER (install Container Manager)"

# One run at a time (a slow run must not overlap the next night's).
LOCK="$DEST/.backup.lock"
# A lock older than 6 hours is left over from a run that was killed (a dump takes seconds).
find "$DEST" -maxdepth 1 -name .backup.lock -type d -mmin +360 -exec rmdir {} \; 2>/dev/null
mkdir "$LOCK" 2>/dev/null || fail "another backup is running (remove $LOCK if no backup is running)"
NAME="${PREFIX}_$(date +%Y%m%d-%H%M%S).dump"
PART="$NAME.part"
ERR="$DEST/.backup.err"
DPID=""
cleanup() {
  # Stopped mid-run (Task Scheduler "stop", shutdown): stop the dump too. docker run passes the
  # signal on to pg_dump in the container.
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null && wait "$DPID" 2>/dev/null
  rm -f "$DEST/$PART" "$ERR"
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT
trap 'log "FAIL stopped by a signal"; exit 130' INT TERM
# Leftovers of a run that was killed (power cut): never a valid dump.
rm -f "$DEST/${PREFIX}_"*.dump.part

# The connection string is read inside the container from the mounted file: it is never on this
# script's command line, in the docker command or in the log.
"$DOCKER" run --rm \
  -v "$SECRET:/run/secrets/db_url:ro" \
  -v "$DEST:/backup" \
  -e OUT="/backup/$PART" \
  -e PGSSLMODE="$SSLMODE" \
  -e PGCONNECT_TIMEOUT=30 \
  -e PGAPPNAME=nas-backup \
  "$IMAGE" sh -euc '
    umask 077
    url=$(head -n 1 /run/secrets/db_url | tr -d "\r")
    pg_dump --format=custom --compress=6 --no-password \
      --schema=public --schema=auth --schema=storage \
      --exclude-table-data=auth.schema_migrations \
      --exclude-table-data=storage.migrations \
      --dbname="$url" --file="$OUT"
    # A dump pg_restore cannot list is not a backup.
    pg_restore --list "$OUT" > /dev/null
  ' > /dev/null 2> "$ERR" &
# In the background and waited for, so a stop signal is handled at once (bash runs traps only
# between commands, and `wait` is interruptible).
DPID=$!
wait "$DPID"
RC=$?
DPID=""

if [ "$RC" -ne 0 ] || [ ! -s "$DEST/$PART" ]; then
  # The first lines of the error (pg_dump never prints the password).
  MSG=$(head -c 400 "$ERR" 2>/dev/null | tr '\n' ' ')
  fail "pg_dump exit $RC: ${MSG:-no output}"
fi

mv -f "$DEST/$PART" "$DEST/$NAME" || fail "could not rename $PART"
chmod 600 "$DEST/$NAME"
BYTES=$(stat -c '%s' "$DEST/$NAME")

# Retention only after a good dump: files older than KEEP days go (the newest KEEP nights stay).
DELETED=$(find "$DEST" -maxdepth 1 -type f -name "${PREFIX}_*.dump" -mtime +"$((KEEP - 1))" -print -delete | wc -l)
COUNT=$(find "$DEST" -maxdepth 1 -type f -name "${PREFIX}_*.dump" | wc -l)

log "OK $NAME $BYTES bytes $(( $(date +%s) - START ))s, deleted $DELETED old, $COUNT kept"
echo "backup OK: $DEST/$NAME ($BYTES bytes)"
exit 0
