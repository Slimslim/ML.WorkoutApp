"""tools/backup/synology_pgdump.sh without a NAS, a database or Docker (docs/BACKUP.md).

A fake `docker` stands in for `docker run postgres:17-alpine ...`: it writes the three .part files
(roles, schema, data) where the container would, or fails, hangs, leaks a secret in its error
text, or stops short. So the script's own logic is tested: the service-file checks, the
all-or-nothing rename, retention by night, the log line, the lock, redaction, stopping, and that
the password never reaches the docker command line. The real pg_dump round trip (backup, restore
into a Supabase Postgres, every row, policy and grant equal) was tested by hand: PR description.
"""
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "backup" / "synology_pgdump.sh"
SERVICE = """[rxlab]
host=db.example.invalid
port=5432
dbname=postgres
user=postgres.example
password=not-a-real-password
sslmode=require
"""

FAKE_DOCKER = r"""#!/bin/bash
# Records each call, then acts like `docker run ... pg_dumpall/pg_dump` according to FAKE_MODE.
printf '%s\n' "$@" >> "$FAKE_ARGS"
echo "----" >> "$FAKE_ARGS"
[ "$1" = "rm" ] && exit 0
base=""; backup=""; secret=""; prev=""
for a in "$@"; do
  case "$prev" in
    -e) case "$a" in BASE=*) base="${a#BASE=}";; esac;;
    -v) case "$a" in *:/backup) backup="${a%:/backup}";; *:/run/secrets:ro) secret="${a%:/run/secrets:ro}";; esac;;
  esac
  prev="$a"
done
[ -r "$secret/pg_service.conf" ] || { echo "service file not mounted" >&2; exit 3; }
write() {
  for k in roles schema data; do printf 'SQL\n-- rxlab backup: %s complete\n' "$k" > "$backup/${base}_$k.sql.part"; done
  # The roles file is written first, so it is older than the data file (seconds, on a real night).
  touch -d '@1000000000' "$backup/${base}_roles.sql.part"
}
case "$FAKE_MODE" in
  ok)    write; exit 0;;
  fail)  printf 'half' > "$backup/${base}_roles.sql.part"
         echo "pg_dumpall: error: connection failed: FATAL:  password authentication failed" >&2; exit 1;;
  leak)  echo "pg_dump: error: invalid line: password=not-a-real-password postgresql://u.x:not-a-real-password@h/db" >&2; exit 1;;
  short) write; printf 'COPY cut off\n' > "$backup/${base}_data.sql.part"; exit 0;;
  hang)  write; sleep 30; exit 0;;
esac
exit 4
"""

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")


@pytest.fixture
def env(tmp_path):
    docker = tmp_path / "docker"
    docker.write_text(FAKE_DOCKER)
    docker.chmod(0o755)
    secret = tmp_path / "pg_service.conf"
    secret.write_text(SERVICE)
    secret.chmod(0o600)
    dest = tmp_path / "RxLabBackup"
    dest.mkdir()
    e = dict(os.environ, DOCKER=str(docker), FAKE_ARGS=str(tmp_path / "args"))
    return {"secret": secret, "dest": dest, "env": e, "args": tmp_path / "args"}


def run(env, *extra, mode="ok"):
    e = dict(env["env"], FAKE_MODE=mode)
    return subprocess.run(["bash", str(SCRIPT), str(env["secret"]), str(env["dest"]), *extra],
                          env=e, capture_output=True, text=True, timeout=60)


def files(dest, pattern="rxlab_*.sql"):
    return sorted(p.name for p in dest.glob(pattern))


def nights(dest):
    return sorted({n.rsplit("_", 1)[0] for n in files(dest)})


def log_lines(dest):
    p = dest / "backup.log"
    return p.read_text().splitlines() if p.exists() else []


def make_old_night(dest, days, kinds=("roles", "schema", "data")):
    t = time.time() - days * 86400 - 600
    for k in kinds:
        p = dest / f"rxlab_202001{days:02d}-030000_{k}.sql"
        p.write_text("old")
        os.utime(p, (t, t))


def test_good_run_writes_three_private_files_and_logs(env):
    r = run(env)
    assert r.returncode == 0, r.stderr
    names = files(env["dest"])
    assert [n.rsplit("_", 1)[1] for n in names] == ["data.sql", "roles.sql", "schema.sql"]
    assert len(nights(env["dest"])) == 1
    for n in names:
        assert (env["dest"] / n).stat().st_mode & 0o777 == 0o600
    assert not list(env["dest"].glob("*.part"))
    assert not (env["dest"] / ".backup.lock").exists()
    (line,) = log_lines(env["dest"])
    assert " OK rxlab_" in line and "(roles, schema, data)" in line
    assert (env["dest"] / "backup.log").stat().st_mode & 0o777 == 0o644
    # The password is read by libpq inside the container (PGSERVICEFILE), never passed on a
    # command line or in the environment.
    args = env["args"].read_text()
    assert "not-a-real-password" not in args
    assert "PGSERVICE=rxlab" in args and "postgres:17-alpine" in args and "--name\nrxlab-backup-" in args
    assert "PGSERVICEFILE=/run/secrets/pg_service.conf" in args and ":/run/secrets:ro" in args
    assert "no-new-privileges" in args and "--read-only" in args
    # The appended statements are read with an empty search_path (schema-qualified, as pg_dump).
    assert args.count("set search_path = ''") == 2
    assert "--schema-only" in args and "--data-only" in args and "--roles-only" in args
    # As the Supabase CLI: auth and storage are left out of the schema, kept in the data.
    internal = args.split("INTERNAL='")[1].split("'")[0].split()
    data_excluded = args.split("DATA_EXCLUDED='")[1].split("'")[0].split()
    assert {"auth", "storage", "extensions", "realtime", "vault"} <= set(internal)
    assert "auth" not in data_excluded and "storage" not in data_excluded
    assert "--exclude-table=auth.schema_migrations" in args


@pytest.mark.parametrize("mode", ["fail", "short"])
def test_failed_or_incomplete_dump_leaves_nothing_and_deletes_nothing(env, mode):
    make_old_night(env["dest"], 30)
    r = run(env, mode=mode)
    assert r.returncode != 0
    assert nights(env["dest"]) == ["rxlab_20200130-030000"]   # the old night survives
    assert not list(env["dest"].glob("*.part"))
    assert log_lines(env["dest"])[-1].split(" ", 2)[1] == "FAIL"
    if mode == "fail":
        # A wrong password must stay readable as such.
        assert "password authentication failed" in log_lines(env["dest"])[-1]
    else:
        assert "data file is incomplete" in r.stderr


def test_secrets_in_error_text_are_redacted(env):
    r = run(env, mode="leak")
    assert r.returncode != 0
    log = (env["dest"] / "backup.log").read_text()
    for text in (log, r.stderr):
        assert "not-a-real-password" not in text
        assert "password=***" in text and "u.x:***@" in text


def test_a_nights_three_files_share_one_time_stamp(env):
    # So the cleanup keeps or deletes a night's set together, never part of it.
    assert run(env).returncode == 0
    times = {(env["dest"] / n).stat().st_mtime for n in files(env["dest"])}
    assert len(times) == 1


def test_retention_keeps_the_newest_14_nights(env):
    for days in range(1, 21):
        make_old_night(env["dest"], days)
    other = env["dest"] / "notes.txt"            # files that are not backups are never touched
    other.write_text("keep")
    os.utime(other, (time.time() - 90 * 86400,) * 2)
    assert run(env).returncode == 0
    kept = nights(env["dest"])
    assert len(kept) == 14                       # tonight + 13 previous nights
    assert "rxlab_20200113-030000" in kept and "rxlab_20200114-030000" not in kept
    assert len(files(env["dest"])) == 14 * 3
    assert other.exists()
    assert "deleted 21 old files, 14 nights kept" in log_lines(env["dest"])[-1]


def test_a_long_outage_keeps_the_newest_nights_not_just_tonight(env):
    # NAS off or Supabase failing for weeks: the first good night must not wipe the history.
    for days in range(40, 60):
        make_old_night(env["dest"], days - 39)
        for p in env["dest"].glob(f"rxlab_202001{days - 39:02d}-*"):
            t = time.time() - days * 86400
            os.utime(p, (t, t))
    assert run(env).returncode == 0
    assert len(nights(env["dest"])) == 14
    assert len(files(env["dest"])) == 14 * 3


def test_orphan_files_older_than_every_kept_night_are_removed(env):
    for days in range(1, 4):
        make_old_night(env["dest"], days)
    make_old_night(env["dest"], 30, kinds=("roles", "schema"))   # a night without its data file
    assert run(env, "2").returncode == 0
    assert not list(env["dest"].glob("rxlab_20200130-*"))
    assert len(nights(env["dest"])) == 2


def test_keep_days_argument(env):
    for days in range(1, 6):
        make_old_night(env["dest"], days)
    assert run(env, "3").returncode == 0
    assert len(nights(env["dest"])) == 3


@pytest.mark.parametrize("mode", [0o644, 0o640, 0o604])
def test_service_file_readable_by_others_is_refused(env, mode):
    env["secret"].chmod(mode)
    r = run(env)
    assert r.returncode != 0
    assert "chmod 600" in r.stderr
    assert not env["args"].exists()              # docker never ran
    assert files(env["dest"]) == []


def test_indented_section_header_is_accepted(env):
    # libpq allows spaces before [rxlab]; a pasted file may have them.
    env["secret"].write_text("  [rxlab]\n" + SERVICE.split("\n", 1)[1])
    env["secret"].chmod(0o600)
    assert run(env).returncode == 0


def test_service_file_without_section_is_refused(env):
    env["secret"].write_text("host=x\npassword=y\n")
    env["secret"].chmod(0o600)
    r = run(env)
    assert r.returncode != 0 and "[rxlab]" in r.stderr
    assert not env["args"].exists()


def test_bad_arguments(env):
    e = env["env"]
    assert subprocess.run(["bash", str(SCRIPT)], env=e, capture_output=True).returncode == 2
    r = subprocess.run(["bash", str(SCRIPT), str(env["secret"]), str(env["dest"] / "nope")],
                       env=e, capture_output=True, text=True)
    assert r.returncode != 0 and "does not exist" in r.stderr
    # Relative paths would make docker -v create a named volume instead of using the folder.
    r = subprocess.run(["bash", str(SCRIPT), "pg_service.conf", str(env["dest"])],
                       env=e, capture_output=True, text=True)
    assert r.returncode != 0 and "absolute path" in r.stderr


def test_running_backup_blocks_a_second_one_but_a_stale_lock_is_cleared(env):
    lock = env["dest"] / ".backup.lock"
    lock.mkdir()
    r = run(env)
    assert r.returncode != 0 and "another backup is running" in r.stderr
    assert lock.exists()                          # not ours: left alone
    stale = time.time() - 7 * 3600
    os.utime(lock, (stale, stale))
    assert run(env).returncode == 0               # a killed run's lock does not block forever
    assert len(nights(env["dest"])) == 1


def test_stopped_run_removes_the_container_and_leaves_no_file(env):
    e = dict(env["env"], FAKE_MODE="hang")
    p = subprocess.Popen(["bash", str(SCRIPT), str(env["secret"]), str(env["dest"])], env=e,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(100):
        if list(env["dest"].glob("*.part")):
            break
        time.sleep(0.05)
    assert list(env["dest"].glob("*.part")), "the fake dump never started"
    os.kill(p.pid, signal.SIGTERM)
    try:
        p.wait(timeout=20)
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
    assert p.returncode == 143
    assert not list(env["dest"].glob("*.part"))
    assert files(env["dest"]) == []
    assert not (env["dest"] / ".backup.lock").exists()
    calls = env["args"].read_text().split("----\n")
    assert any(c.startswith("rm\n-f\nrxlab-backup-") for c in calls), "the container was not removed"
    assert "FAIL stopped by a signal" in log_lines(env["dest"])[-1]


def test_leftover_part_from_a_power_cut_is_removed(env):
    (env["dest"] / "rxlab_20200101-030000_data.sql.part").write_text("half")
    assert run(env).returncode == 0
    assert not list(env["dest"].glob("*.part"))


def test_kept_pre_change_backups_are_never_deleted(env):
    # docs/BACKUP.md step 8: a backup kept before a database change is renamed keep_rxlab_...
    t = time.time() - 400 * 86400
    for k in ("roles", "schema", "data"):
        p = env["dest"] / f"keep_rxlab_20200101-030000_{k}.sql"
        p.write_text("kept")
        os.utime(p, (t, t))
    assert run(env).returncode == 0
    assert len(files(env["dest"], "keep_rxlab_*.sql")) == 3



# The script that runs inside the container (between INNER=$(cat <<'EOS' and EOS), run with bash
# and stand-in pg_dumpall/pg_dump/psql on PATH. Checks the Supabase CLI's line rewrites, the extra
# schema-file sections, and that a failing dump leaves no completion line.
STUBS = {
    "pg_dumpall": r"""#!/bin/sh
cat <<'X'
\restrict abc
CREATE ROLE "anon";
ALTER ROLE "anon" WITH NOSUPERUSER NOINHERIT;
CREATE ROLE "reporting";
ALTER ROLE "reporting" WITH NOSUPERUSER INHERIT NOCREATEROLE NOREPLICATION;
GRANT "pg_read_all_data" TO "authenticated";
GRANT SET ON PARAMETER "session_replication_role" TO "supabase_admin";
X
""",
    "pg_dump": r"""#!/bin/sh
[ -n "${STUB_FAIL:-}" ] && { echo "pg_dump: error: boom" >&2; exit 1; }
case " $* " in
  *" --schema-only "*) cat <<'X'
\restrict abc
SET transaction_timeout = 0;
CREATE SCHEMA "public";
CREATE TABLE "public"."t" (id int);
CREATE FUNCTION "public"."f"() RETURNS int LANGUAGE sql AS 'select 1';
CREATE EVENT TRIGGER "ensure_rls" ON ddl_command_end
         WHEN TAG IN ('CREATE TABLE')
   EXECUTE FUNCTION "public"."rls_auto_enable"();
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
GRANT USAGE ON SCHEMA "auth" TO "authenticated";
COMMENT ON EXTENSION "pg_jsonschema" IS 'x';
X
  ;;
  *) printf 'COPY "public"."t" ("id") FROM stdin;\n1\n\\.\n';;
esac
""",
    "psql": r"""#!/bin/sh
case "$*" in
  *pg_extension*) echo 'CREATE EXTENSION IF NOT EXISTS pg_jsonschema WITH SCHEMA extensions;';;
  *pg_policies*) printf 'DROP POLICY IF EXISTS "p" ON storage.objects;\nCREATE POLICY "p" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (true);\n';;
esac
""",
    "timeout": "#!/bin/sh\nshift 3\nexec \"$@\"\n",
}


def inner_script():
    text = SCRIPT.read_text()
    return text.split("INNER=$(cat <<'EOS'\n", 1)[1].split("\nEOS\n", 1)[0]


def run_inner(tmp_path, **extra):
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    for name, body in STUBS.items():
        (stubs / name).write_text(body)
        (stubs / name).chmod(0o755)
    out = tmp_path / "out"
    out.mkdir()
    e = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", BACKUP_DIR=str(out),
             BASE="rxlab_t", DUMP_TIMEOUT="5", **extra)
    r = subprocess.run(["bash", "-c", inner_script()], env=e, capture_output=True, text=True,
                       timeout=30)
    return r, {k: (out / f"rxlab_t_{k}.sql.part").read_text()
               for k in ("roles", "schema", "data") if (out / f"rxlab_t_{k}.sql.part").exists()}


def test_inner_script_applies_the_supabase_cli_rewrites(tmp_path):
    r, f = run_inner(tmp_path)
    assert r.returncode == 0, r.stderr
    roles, schema, data = f["roles"], f["schema"], f["data"]
    # roles: reserved roles and their grants commented out, custom roles kept without superuser-only attributes
    assert '-- CREATE ROLE "anon"' in roles and '-- ALTER ROLE "anon"' in roles
    assert '\nCREATE ROLE "reporting";' in roles
    assert "NOREPLICATION" not in roles and "NOSUPERUSER" not in roles.replace('-- ALTER ROLE "anon"', "")
    assert '-- GRANT "pg_read_all_data" TO "authenticated"' in roles
    assert '-- GRANT SET ON PARAMETER "session_replication_role" TO "supabase_admin"' in roles
    assert "-- \\restrict abc" in roles and roles.rstrip().endswith("-- rxlab backup: roles complete")
    # schema: idempotent creates, platform statements commented out, our three additions in place
    assert 'CREATE SCHEMA IF NOT EXISTS "public"' in schema
    assert 'CREATE TABLE IF NOT EXISTS "public"."t"' in schema
    assert 'CREATE OR REPLACE FUNCTION "public"."f"' in schema
    assert '-- CREATE EVENT TRIGGER' in schema and '--          WHEN TAG IN' in schema
    assert '-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin"' in schema
    assert '-- GRANT USAGE ON SCHEMA "auth"' in schema
    assert '-- COMMENT ON EXTENSION' in schema and "-- SET transaction_timeout = 0;" in schema
    assert schema.index("CREATE EXTENSION IF NOT EXISTS pg_jsonschema") < schema.index('CREATE TABLE IF NOT EXISTS')
    assert schema.index("REVOKE ALL ON TABLES") < schema.index('CREATE TABLE IF NOT EXISTS')
    assert schema.index('CREATE TABLE IF NOT EXISTS') < schema.index('CREATE POLICY "p" ON storage.objects')
    assert schema.rstrip().endswith("-- rxlab backup: schema complete")
    # data: triggers off while loading, session reset after, complete
    assert data.startswith("SET session_replication_role = replica;")
    assert 'COPY "public"."t"' in data and "RESET ALL;" in data
    assert data.rstrip().endswith("-- rxlab backup: data complete")


def test_inner_script_stops_at_a_failing_dump_without_a_completion_line(tmp_path):
    r, f = run_inner(tmp_path, STUB_FAIL="1")
    assert r.returncode != 0
    assert "boom" in r.stderr
    assert "-- rxlab backup: schema complete" not in f.get("schema", "")
    assert "data" not in f
