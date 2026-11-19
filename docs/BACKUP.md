# Database backup to the NAS

The Supabase project is on the Free plan, which has **no backups and no point-in-time
recovery**. The only backup of the database is the one this page sets up:

- a dump every night at 03:00 to the Synology NAS;
- the last 14 nights are kept;
- optionally, a copy off-site (Hyper Backup).

You set it up once (about 30 minutes), test a restore once a month, and take an extra dump by hand
before any change to the database.

Scripts: `tools/backup/` in this repo.

| File | What it is |
|---|---|
| `synology_pgdump.sh` | The nightly backup. |
| `synology_restore_test.sh` | The monthly restore test. |
| `restore_before.sql`, `restore_after.sql` | Only used to restore into a new Supabase project. |

Placeholders on this page:

| Placeholder | What it stands for |
|---|---|
| `<PASSWORD>` | The database password. Never put it in the repo, an issue or a chat. |
| `<PROJECT-REF>` | The project's id. |
| `<REGION>` | The project's region. |
| `<admin>` | Your DSM admin user. |
| `<NAS-IP>` | The NAS's local address. |

## What the dump contains, and why

One file per night, `rxlab_YYYYMMDD-HHMMSS.dump`, in pg_dump's compressed custom format. It holds
three schemas, with their tables, data, functions, policies and grants:

| Schema | What is in it |
|---|---|
| `public` | Everything the app made: the workout library, drafts, gyms, uploads index, v2 tables. |
| `auth` | The user accounts, `auth.users`, so accounts can be restored. |
| `storage` | The list of uploaded files and buckets. **Not the files themselves.** Recordings live in Supabase Storage and are not in a database dump. |

What is left out, and why:

- **Supabase's internal schemas** (`extensions`, `realtime`, `vault`, `graphql`, `pgsodium`,
  `supabase_functions`, ...). A new Supabase project creates these itself, and restoring them over it
  fails with permission errors. Supabase's own guide says the same: "using raw `pg_dump` directly will
  include Supabase internals and cause permission errors during restore".
- **The data of the two tables Supabase's services keep for themselves**, `auth.schema_migrations`
  and `storage.migrations`. A new project has its own.

So one file is enough both to restore the whole project and to check it on the NAS.

**The dump holds user accounts, emails and password hashes.** Treat it like a password:

- the dump files are readable by root only (600);
- the folder is for administrators only;
- an off-site copy must be encrypted (step 6).

## 1. A folder for the dumps (File Station)

1. **Control Panel → Shared Folder → Create.**
   - Name: `Backups` (or use an existing admin-only shared folder).
   - Tick "Hide this shared folder in My Network Places".
   - Leave the Recycle Bin off for it: old dumps are deleted on purpose.
2. Permissions: **administrators: Read/Write; every other user and group: No access**.
3. In **File Station**, open `Backups` and create the folder `rxlab`. The dumps go to
   `/volume1/Backups/rxlab` (use your volume number if it is not `volume1`).

## 2. Turn on SSH for the setup (Control Panel → Terminal & SNMP)

Tick **Enable SSH service**, then Apply. You can turn it off again when the setup is done; the nightly
task does not need it.

From your Mac: `ssh <admin>@<NAS-IP>`, then `sudo -i` (asks your DSM password). You are now root.
The prompt ends with `#`.

## 3. The scripts and the password file (root only)

These live outside the shared folders, in `/volume1/@rxlab`. File Station does not show folders whose
name starts with `@`, and shared-folder permission changes cannot open them up.

1. Copy the three files from `tools/backup/` in this repo into `Backups/rxlab-setup` with File Station
   (drag and drop). Then, as root:

   ```sh
   mkdir -p /volume1/@rxlab
   chmod 700 /volume1/@rxlab
   cp /volume1/Backups/rxlab-setup/synology_*.sh /volume1/@rxlab/
   chmod 700 /volume1/@rxlab/*.sh
   rm -r /volume1/Backups/rxlab-setup
   ```

2. Get the connection string:
   1. In the Supabase dashboard, go to **Connect → Session pooler**. It looks like:
      `postgresql://postgres.<PROJECT-REF>:[YOUR-PASSWORD]@aws-0-<REGION>.pooler.supabase.com:5432/postgres`
   2. Replace `[YOUR-PASSWORD]` with the database password. If you don't know it, set a new one under
      **Database → Settings**; the app does not use it.
   3. If the password has `@ : / # ? %` in it, write those as `%40 %3A %2F %23 %3F %25`.

   Use the **Session** pooler, not the Transaction one: pg_dump needs a session. The direct
   connection (`db.<PROJECT-REF>.supabase.co`) is IPv6 only, so it is no use from most home networks.

3. Create the password file without the password ever landing in the shell history. As root:

   ```sh
   umask 077
   cat > /volume1/@rxlab/db_url
   ```

   Paste the connection string, press Enter, then Ctrl-D. Then:

   ```sh
   chmod 600 /volume1/@rxlab/db_url
   ls -l /volume1/@rxlab/db_url     # must show -rw------- 1 root root
   ```

   The backup refuses to run if anyone but root can read this file.

## 4. The postgres image (Container Manager)

1. Install **Container Manager** from Package Center if it is not there.
2. **Container Manager → Registry**, search `postgres`, select the official `postgres` image,
   **Download**, and choose the tag **`17-alpine`**.
3. It appears under **Image**.

The NAS (Intel, x86-64) runs it as is. Nothing else is installed. The backup starts a container
from this image for a few seconds each night and removes it.

When Supabase moves the project to a newer Postgres (18), download the matching tag and change
`IMAGE` (step 5). pg_dump must be the same major version as the server or newer.

## 5. The nightly task (Control Panel → Task Scheduler)

1. **Create → Scheduled Task → User-defined script.**
2. **General**:
   - Task: `Rx Lab database backup`
   - User: **root**
   - Enabled
3. **Schedule**: Run on the following days: **Daily**. First run time: **03:00**. Frequency: once a day.
4. **Task Settings**:
   - Tick **Send run details by email** and **Send run details only when the script terminates
     abnormally**. This needs Control Panel → Notification → Email set up once.
   - Run command:

     ```sh
     bash /volume1/@rxlab/synology_pgdump.sh /volume1/@rxlab/db_url /volume1/Backups/rxlab 14
     ```

     The last number is how many nights to keep.
5. OK.

**First run now:** select the task, then click **Run**. After a few seconds, check it worked:

- In **File Station**, `Backups/rxlab` holds `rxlab_<date>-<time>.dump`. Today it is a few hundred KB
  at most.
- `Backups/rxlab/backup.log` ends with a line like:
  `2026-11-20T03:00:04+0100 OK rxlab_20261120-030001.dump 412345 bytes 3s, deleted 0 old, 1 kept`
- Or, as root: `tail -3 /volume1/Backups/rxlab/backup.log`.

A failed night:

- writes `FAIL` and the reason in the log;
- leaves no half-written file;
- deletes no older dump;
- exits with an error, so DSM emails you.

The usual reasons:

| Reason in the log | What to do |
|---|---|
| `password authentication failed` | The password changed: edit `db_url`. |
| `connection ... failed` | The internet or Supabase is down; the next night retries. |
| `mode 644; run: chmod 600` | Someone changed the file's permissions. |
| `docker not found` | Container Manager is not installed. |

If a dump is ever bigger than about 1 GB, a night takes minutes, not seconds; nothing needs to change.

## 6. Off-site copy (optional, recommended): Hyper Backup

The NAS is one place: a fire, theft or a failed volume takes the backups with it.

1. Install **Hyper Backup**.
2. Create → **Data backup task** → a destination: Synology C2, a USB disk, another NAS or a cloud drive.
3. Select the folder `Backups/rxlab`.
4. Schedule: daily at **04:00**, after the dump.
5. **Tick "Enable client-side encryption"** and store that password somewhere other than the NAS.
   The dumps hold user accounts.
6. Rotation: keep about 30 versions.

## 7. Restore test, every month

A backup that was never restored is a hope, not a backup. Once a month, as root:

```sh
bash /volume1/@rxlab/synology_restore_test.sh "$(ls -t /volume1/Backups/rxlab/rxlab_*.dump | head -1)"
```

What the test does:

1. Starts a throwaway `postgres:17-alpine` container. It runs in memory, with no network port opened
   to the LAN.
2. Restores the newest dump into it.
3. Counts the rows of every table and compares them with the rows in the dump.
4. Removes the container.

It ends with `restore test OK: N tables, every row restored` (exit 0), or names the table that lost
rows (exit 1). It takes under a minute. Lines starting `skipped:` are Supabase-only objects a plain
postgres doesn't have; they are expected.

Also look at the counts against the dashboard (Table Editor) once:

- `public.workout_library` = the library rows;
- `auth.users` = the number of accounts.

You can schedule it too: a second Task Scheduler task, user root, monthly (the 1st, 05:00), the same
command, with the email-on-error setting.

## 8. Before any change to the database: a manual backup

Before applying a migration, running a data fix or deleting rows:

1. Run the backup task by hand: Task Scheduler → select **Rx Lab database backup** → **Run**.
2. Check the log's last line is `OK` and note the file name.
3. Copy that file into a subfolder, for example `Backups/rxlab/before-2026-11-20-backend-v2/`.
   Files in subfolders are never deleted by the 14-day cleanup.
4. Run the restore test on it (step 7).
5. Only then change the database. Write the file name in the PR or issue.

Undoing a change: use the change's own rollback script first (for example
`supabase/rollback/20261118_backend_v2_rollback.sql`). The dump is the last resort.

## 9. Restore into Supabase (disaster: the project is lost or broken)

Into a **new** Supabase project, from the NAS, as root. Replace the placeholders; the connection
string is the **new** project's Session pooler string.

1. Create the new project (database.new) on Postgres 17.
2. In its **SQL editor**, run `tools/backup/restore_before.sql`. It does two things:
   - enables `pg_jsonschema`;
   - stops Supabase from granting everything to `anon`/`authenticated` on the tables the restore
     creates, so the restored tables keep exactly their old grants.
3. Restore auth and storage data first (the library has foreign keys to `auth.users`), then the
   app's schema. Each line is one command:

   ```sh
   umask 077; cat > /volume1/@rxlab/new_db_url      # paste the new project's string, Enter, Ctrl-D
   D=$(ls -t /volume1/Backups/rxlab/rxlab_*.dump | head -1)
   /usr/local/bin/docker run --rm -v "$D:/b.dump:ro" -v /volume1/@rxlab/new_db_url:/u:ro postgres:17-alpine \
     sh -c 'pg_restore --data-only --schema=auth --schema=storage --exit-on-error -d "$(cat /u)" /b.dump'
   /usr/local/bin/docker run --rm -v "$D:/b.dump:ro" -v /volume1/@rxlab/new_db_url:/u:ro postgres:17-alpine \
     sh -c 'pg_restore --no-owner --schema=public -d "$(cat /u)" /b.dump'
   ```

   The second command reports a few `permission denied to change default privileges` and
   `schema "public" already exists` errors. They are expected: the new project already has both.
4. In the SQL editor, run `tools/backup/restore_after.sql`. It puts Supabase's normal defaults back
   for tables made later.
5. Check the counts (step 7).
6. Then, outside the database:
   - Point the app at the new project. Its URL and keys change: a new app build.
   - Set up Auth again: Apple sign-in, email settings, redirect URLs.
   - Copy the Storage files.
   - Users sign in again: their old sessions are not valid in the new project.
7. Delete `/volume1/@rxlab/new_db_url`.

Tested on a copy (19 Nov 2026): the restored database matched the source in every table's rows,
`auth.users`, policies, grants, function permissions, triggers and RLS flags. The copy was a local
Supabase Postgres 17.11 with the build-17 migrations applied and synthetic users.

## What has not been tested on the NAS itself

The scripts were tested in a Linux container, with Docker 29 and `postgres:17-alpine` (pg_dump
17.12), against a local Supabase Postgres 17.11. Not tested yet:

| Not tested | What could go wrong |
|---|---|
| DSM 7.2.2's Task Scheduler running the command as root | Paths, `bash` |
| DSM's `stat`, `find` and `docker` (Container Manager) | Different versions from the test machine |
| A real Session pooler connection from the home network | It needs TLS (`PGSSLMODE=require`, the default here) |
| File Station showing `backup.log` | It should, the log is 644 |
| `chmod 600` on a file under `/volume1/@rxlab` | It should stick there, outside the shared-folder permissions |
| Hyper Backup | Not tested at all |

The first manual run (step 5) and the first restore test (step 7) check all of these. If one fails,
the log line says which check stopped it.
