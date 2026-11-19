"""tools/backup/synology_pgdump.sh without a NAS, a database or Docker (docs/BACKUP.md).

A fake `docker` stands in for `docker run postgres:17-alpine pg_dump ...`: it writes the dump file
(or fails, or hangs) where the container would, so the script's own logic is tested: the
connection-file checks, the .part file and rename, retention, the log line, the lock, and that the
connection string never reaches the docker command line. The real pg_dump/pg_restore round trip
was tested by hand against a local Supabase Postgres (PR description).
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
SECRET_TEXT = "postgresql://user.example:not-a-real-password@db.example.invalid:5432/postgres"

FAKE_DOCKER = r"""#!/bin/bash
# Records its arguments, then acts like `docker run ... pg_dump` according to FAKE_MODE.
printf '%s\n' "$@" > "$FAKE_ARGS"
out=""; backup=""; secret=""
prev=""
for a in "$@"; do
  case "$prev" in
    -e) case "$a" in OUT=*) out="${a#OUT=}";; esac;;
    -v) case "$a" in *:/backup) backup="${a%:/backup}";; *:/run/secrets/db_url:ro) secret="${a%:/run/secrets/db_url:ro}";; esac;;
  esac
  prev="$a"
done
host_out="$backup/${out#/backup/}"
[ -r "$secret" ] || { echo "secret not mounted" >&2; exit 3; }
case "$FAKE_MODE" in
  ok)   printf 'PGDMP fake dump\n' > "$host_out"; exit 0;;
  fail) printf 'PGDMP half' > "$host_out"; echo "pg_dump: error: connection failed" >&2; exit 1;;
  hang) printf 'PGDMP half' > "$host_out"; sleep 30; exit 0;;
esac
exit 4
"""

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")


@pytest.fixture
def env(tmp_path):
    docker = tmp_path / "docker"
    docker.write_text(FAKE_DOCKER)
    docker.chmod(0o755)
    secret = tmp_path / "db_url"
    secret.write_text(SECRET_TEXT + "\n")
    secret.chmod(0o600)
    dest = tmp_path / "backups"
    dest.mkdir()
    e = dict(os.environ, DOCKER=str(docker), FAKE_ARGS=str(tmp_path / "args"), FAKE_MODE="ok")
    return {"secret": secret, "dest": dest, "env": e, "args": tmp_path / "args"}


def run(env, *extra, mode="ok"):
    e = dict(env["env"], FAKE_MODE=mode)
    return subprocess.run(["bash", str(SCRIPT), str(env["secret"]), str(env["dest"]), *extra],
                          env=e, capture_output=True, text=True, timeout=60)


def dumps(dest):
    return sorted(p.name for p in dest.glob("rxlab_*.dump"))


def log_lines(dest):
    p = dest / "backup.log"
    return p.read_text().splitlines() if p.exists() else []


def test_good_run_writes_a_private_dump_and_logs(env):
    r = run(env)
    assert r.returncode == 0, r.stderr
    names = dumps(env["dest"])
    assert len(names) == 1 and names[0].startswith("rxlab_")
    assert (env["dest"] / names[0]).stat().st_mode & 0o777 == 0o600
    assert not list(env["dest"].glob("*.part"))
    assert not (env["dest"] / ".backup.lock").exists()
    (line,) = log_lines(env["dest"])
    assert " OK " + names[0] in line
    # The connection string is read inside the container, never passed on the command line.
    args = env["args"].read_text()
    assert "not-a-real-password" not in args and "postgresql://" not in args
    assert "postgres:17-alpine" in args and "--schema=auth" in args


def test_failed_dump_leaves_nothing_and_deletes_nothing(env):
    old = env["dest"] / "rxlab_20200101-030000.dump"
    old.write_text("old")
    stamp = time.time() - 30 * 86400
    os.utime(old, (stamp, stamp))
    r = run(env, mode="fail")
    assert r.returncode != 0
    assert dumps(env["dest"]) == [old.name]          # the old dump survives a failed night
    assert not list(env["dest"].glob("*.part"))
    assert "FAIL pg_dump exit 1" in log_lines(env["dest"])[-1]
    assert "not-a-real-password" not in (env["dest"] / "backup.log").read_text()


def test_retention_keeps_the_newest_14_nights(env):
    now = time.time()
    for days in range(1, 21):
        p = env["dest"] / f"rxlab_old{days:02d}.dump"
        p.write_text("x")
        t = now - days * 86400 - 600
        os.utime(p, (t, t))
    other = env["dest"] / "notes.txt"            # files that are not dumps are never touched
    other.write_text("keep")
    os.utime(other, (now - 90 * 86400,) * 2)
    assert run(env).returncode == 0
    names = dumps(env["dest"])
    assert len(names) == 14                      # tonight + 13 previous nights
    assert "rxlab_old13.dump" in names and "rxlab_old14.dump" not in names
    assert other.exists()
    assert "deleted 7 old, 14 kept" in log_lines(env["dest"])[-1]


def test_keep_days_argument(env):
    for days in range(1, 6):
        p = env["dest"] / f"rxlab_old{days}.dump"
        p.write_text("x")
        t = time.time() - days * 86400 - 600
        os.utime(p, (t, t))
    assert run(env, "3").returncode == 0
    assert len(dumps(env["dest"])) == 3


@pytest.mark.parametrize("mode", [0o644, 0o640, 0o604])
def test_connection_file_readable_by_others_is_refused(env, mode):
    env["secret"].chmod(mode)
    r = run(env)
    assert r.returncode != 0
    assert "chmod 600" in r.stderr
    assert not env["args"].exists()              # docker never ran
    assert dumps(env["dest"]) == []


def test_missing_arguments_and_bad_folder(env):
    e = env["env"]
    assert subprocess.run(["bash", str(SCRIPT)], env=e, capture_output=True).returncode == 2
    r = subprocess.run(["bash", str(SCRIPT), str(env["secret"]), str(env["dest"] / "nope")],
                       env=e, capture_output=True, text=True)
    assert r.returncode != 0 and "does not exist" in r.stderr


def test_running_backup_blocks_a_second_one_but_a_stale_lock_is_cleared(env):
    lock = env["dest"] / ".backup.lock"
    lock.mkdir()
    r = run(env)
    assert r.returncode != 0 and "another backup is running" in r.stderr
    assert lock.exists()                          # not ours: left alone
    stale = time.time() - 7 * 3600
    os.utime(lock, (stale, stale))
    assert run(env).returncode == 0               # a killed run's lock does not block forever
    assert len(dumps(env["dest"])) == 1


def test_stopped_run_leaves_no_partial_file(env):
    e = dict(env["env"], FAKE_MODE="hang")
    p = subprocess.Popen(["bash", str(SCRIPT), str(env["secret"]), str(env["dest"])], env=e,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(100):
        if list(env["dest"].glob("*.part")):
            break
        time.sleep(0.05)
    assert list(env["dest"].glob("*.part")), "the fake dump never started"
    os.kill(p.pid, signal.SIGTERM)
    p.wait(timeout=20)
    os.killpg(p.pid, signal.SIGKILL) if p.poll() is None else None
    assert p.returncode != 0
    assert not list(env["dest"].glob("*.part"))
    assert dumps(env["dest"]) == []
    assert not (env["dest"] / ".backup.lock").exists()


def test_leftover_part_from_a_power_cut_is_removed(env):
    (env["dest"] / "rxlab_20200101-030000.dump.part").write_text("half")
    assert run(env).returncode == 0
    assert not list(env["dest"].glob("*.part"))
