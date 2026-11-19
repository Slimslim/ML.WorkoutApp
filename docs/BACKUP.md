# Database backup to the NAS

The Supabase project is on the Free plan, which has **no backups and no point-in-time recovery**.
The only backup of the database is the one this page sets up:

- a backup every night at 03:00 to the Synology NAS (DS916+, DSM 7.2.2), into the shared folder
  `/volume1/RxLabBackup`;
- the last 14 nights are kept;
- a restore test once a month;
- a backup by hand before any change to the database.

Setup takes about 30 minutes.

Scripts: `tools/backup/` in this repo.

| File | What it is |
|---|---|
| `synology_pgdump.sh` | The nightly backup. |
| `synology_restore_test.sh` | The monthly restore test. |

Placeholders on this page:

| Placeholder | What it stands for |
|---|---|
| `<PASSWORD>` | The database password. Never put it in the repo, an issue or a chat. |
| `<PROJECT-REF>` | The project's id. |
| `<REGION>` | The project's region. |
| `<admin>` | Your DSM admin user. |
| `<NAS-IP>` | The NAS's local address. |

## What a backup is

Each night writes three files into `/volume1/RxLabBackup`, the same three that Supabase's own
`supabase db dump` makes and that its restore guide loads:

| File | Contents |
|---|---|
| `rxlab_<date>-<time>_roles.sql` | Database roles the project made itself. None today. Supabase's own roles (`anon`, `authenticated`, ...) are left out because every project has them. |
| `rxlab_<date>-<time>_schema.sql` | The app's tables, functions, policies, grants and triggers. |
| `rxlab_<date>-<time>_data.sql` | Every row, including the user accounts (`auth.users`) and the list of uploaded files (`storage.objects`). |

The schema file follows the CLI's rules:

- the same pg_dump flags and line rewrites;
- the same Supabase-managed schemas left out (`auth`, `storage`, `extensions`, `realtime`,
  `vault`, ...), because a new project creates those itself.

It adds three things the CLI leaves to manual steps, so that loading the file into a new project
needs nothing else:

| Where in the file | What it adds | Why |
|---|---|---|
| The start | `CREATE EXTENSION` for the extensions the tables need (`pg_jsonschema`, once build 17's backend is applied) | The tables cannot be created without them. |
| The start | The project's automatic grants are switched off while the file loads; pg_dump's own lines at the end of the file switch them back on | Without this, a new project gives `anon` and `authenticated` full rights on every restored table. Every table and function would lose its own grants. |
| The end | The 4 policies on `storage.objects` from the uploads migration | Without them, nobody can upload or download a recording after a restore. The CLI's schema dump does not contain them. |

The data file:

- includes `auth` and `storage`;
- leaves out the tables Supabase's services keep for themselves (`auth.schema_migrations`,
  `storage.migrations`), as the CLI does.

What a backup does **not** contain:

- **The uploaded files themselves** (the recordings): they live in Supabase Storage, not in the
  database.
- **Auth settings** (Apple sign-in, email), **API keys** and **edge functions**: they are project
  settings, not data.

**The files hold user accounts, emails and password hashes.** Treat them like a password:

- they are readable by root only (600);
- the folder is for administrators only;
- an off-site copy must be encrypted (step 6).

### Why `postgres:17-alpine`, not `supabase/postgres`

The backup runs pg_dump from the official **`postgres:17-alpine`** image.

- **Restorability doesn't depend on the image.** It comes from how the dump is made: the CLI's
  flags, schema lists and rewrites, which the script reproduces. pg_dump 17 is the same program in
  both images.
- **It was tested.** The three files were loaded into Supabase's own Postgres 17.11 with Supabase's
  documented restore command. The result equalled the source: every row, policy, grant and trigger
  (see "Tested").
- **The official image is smaller:** 424 MB on disk, against 1.57 GB for `supabase/postgres:17.11.0.011`.
  That matters on a NAS with 8 GB of RAM and a 1.6 GHz CPU.
- **It is the plain tool for the job.** The Supabase image is a whole database server with
  Supabase's extensions; it is built to run Supabase, not to run pg_dump.
- **One Supabase image tag crashed in testing.** `17.6.1.104` crashes whenever a signed-out
  caller runs a function it may not execute.

When Supabase moves the project to Postgres 18, use `postgres:18-alpine`. pg_dump must be the same
major version as the server or newer.

## 1. The shared folder `RxLabBackup` (already made)

`/volume1/RxLabBackup` is the backup folder.

- It is on Btrfs, with data checksums on and a 20 GB quota.
- It is for administrators only. Check under **Control Panel → Shared Folder → RxLabBackup →
  Edit → Permissions**: administrators Read/Write, everyone else No access.
- Backups go straight into it, with no subfolder.

What its settings mean for the backup:

- **Recycle Bin (on).** The nightly cleanup deletes old backups from the shell, which does not go
  through the Recycle Bin, so the bin does not fill with old backups. Only files you delete in
  File Station or over the network land there.
  - Under **Edit → General**, tick "Restrict access to administrators only" for the Recycle Bin.
  - Empty it now and then: **Control Panel → Task Scheduler → Create → Scheduled Task → Recycle Bin**.
- **Quota 20 GB.** Today one night is about 1–6 MB, so 14 nights are under 100 MB. The log line
  gives each night's size; look again if it ever passes 500 MB.
- **Data checksums.** Btrfs notices if a backup file is silently damaged on disk.
- **Snapshots (recommended, free).** In **Snapshot Replication**, take a daily snapshot of
  `RxLabBackup` and keep 30.
  - The nightly cleanup keeps 14 nights. If a bad change went unnoticed for longer, every kept
    backup would already contain it.
  - Snapshots keep older nights at almost no space cost.

## 2. Turn on SSH for the setup (Control Panel → Terminal & SNMP)

Tick **Enable SSH service**, then Apply. Turn it off again when the setup is done; the nightly task
does not need it.

From your Mac: `ssh <admin>@<NAS-IP>`, then `sudo -i` (asks your DSM password). You are now root.
The prompt ends with `#`.

## 3. The scripts and the password file

**Where:** `/volume1/@rxlab`, outside the `RxLabBackup` share, readable by root only. Why not a
root-only file inside the share:

- **The Recycle Bin** would keep every old version of the password file each time you replace it,
  under the share's permissions, not the file's.
- **Permission edits** in the DSM Shared Folder dialog can apply to everything inside the share
  and widen a file's access without you noticing.
- **Copies.** Hyper Backup and snapshots of the share would copy the password everywhere the
  backups go.
- **Visibility.** Folders whose name starts with `@` are not shown in File Station or over the
  network, and only `chmod` decides who reads them.

The backup refuses to run if anyone but root can read the file, so a mistake shows up the next night.

1. Copy the two scripts from `tools/backup/` in this repo into `RxLabBackup` with File Station
   (drag and drop). Then, as root:

   ```sh
   mkdir -p /volume1/@rxlab
   chmod 700 /volume1/@rxlab
   mv /volume1/RxLabBackup/synology_pgdump.sh /volume1/RxLabBackup/synology_restore_test.sh /volume1/@rxlab/
   chmod 700 /volume1/@rxlab/*.sh
   ```

   (`mv` from the shell does not go through the Recycle Bin.)

2. Get the connection details:
   1. In the Supabase dashboard, go to **Connect → Session pooler → View parameters**: host, port,
      database, user.
   2. The password is the database password. If you don't know it, set a new one under
      **Database → Settings**; the app does not use it.
   3. Use the **Session** pooler, not the Transaction one: pg_dump needs a session. The direct
      connection is IPv6 only, so it is no use from most home networks.

3. Write the password file, a libpq "service file". It holds the password as it is, with no
   escaping, and nothing ever puts it on a command line. As root:

   ```sh
   umask 077
   cat > /volume1/@rxlab/pg_service.conf
   ```

   Paste the lines below, filled in, then press Enter and Ctrl-D:

   ```
   [rxlab]
   host=aws-0-<REGION>.pooler.supabase.com
   port=5432
   dbname=postgres
   user=postgres.<PROJECT-REF>
   password=<PASSWORD>
   sslmode=require
   ```

   Then:

   ```sh
   chmod 600 /volume1/@rxlab/pg_service.conf
   ls -l /volume1/@rxlab/pg_service.conf      # must show -rw------- 1 root root
   ```

## 4. The image `postgres:17-alpine` (Container Manager)

**`postgres:17-alpine` is already downloaded.** To check, open **Container Manager → Image**: it
lists `postgres` with the tag `17-alpine`.

If it is ever missing:
1. **Container Manager → Registry**, search `postgres`.
2. Select the official `postgres` image, **Download**, and choose the tag **`17-alpine`**.

The NAS (Intel, x86-64) runs it as is, and nothing else is installed. Each night the backup starts
a container from it for a few seconds, then removes it.

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
     bash /volume1/@rxlab/synology_pgdump.sh /volume1/@rxlab/pg_service.conf /volume1/RxLabBackup 14
     ```

     The last number is how many nights to keep.
5. OK.

**First run now:** select the task, then click **Run**. After a few seconds, check it worked:

- **File Station → RxLabBackup** shows three new files: `rxlab_<date>-<time>_roles.sql`,
  `_schema.sql` and `_data.sql`.
- `backup.log` in the same folder ends with a line like:
  `2026-11-20T03:00:04+0100 OK rxlab_20261120-030001 (roles, schema, data) 4123456 bytes 3s, deleted 0 old files, 1 nights kept`

A failed night:

- writes `FAIL` and the reason in `backup.log`;
- leaves no half-written file;
- deletes no older backup;
- exits with an error, so DSM emails you.

A dump that hangs is stopped after 30 minutes. Stopping the task in Task Scheduler stops the dump
too.

The usual reasons:

| Reason in the log | What to do |
|---|---|
| `password authentication failed` | The password changed: edit `pg_service.conf`. |
| `connection ... failed` or `timeout` | The internet or Supabase is down; the next night retries. |
| `mode 644; run: chmod 600` | Someone changed the file's permissions. |
| `no [rxlab] section` | The first line of the password file is missing. |
| `docker not found` | Container Manager is not installed. |
| `another backup is running` | A run was killed. It clears itself after 6 hours. |

## 6. Off-site copy: Hyper Backup (recommended)

The NAS is one place: a fire, theft or a failed volume takes the backups with it.

1. Install **Hyper Backup**.
2. Create → **Data backup task** → a destination: Synology C2, a USB disk, another NAS or a cloud drive.
3. Select the folder `RxLabBackup`.
4. Schedule: daily at **04:00**, after the backup.
5. **Tick "Enable client-side encryption"** and keep that password somewhere other than the NAS.
   The files hold user accounts.
6. Rotation: keep about 30 versions.

## 7. Restore test, every month

A backup that was never restored is a hope, not a backup. Once a month, as root:

```sh
bash /volume1/@rxlab/synology_restore_test.sh /volume1/RxLabBackup
```

What the test does:

1. Takes the newest night's three files and checks each one is complete.
2. Starts a throwaway `postgres:17-alpine` container. The database is in memory and the container
   opens no port on the LAN.
3. Loads the three files into it.
4. Counts every table's rows and compares them with the rows in the backup.
5. Removes the container.

Output:

- It ends with `restore test OK: rxlab_..., N tables, every row restored` (exit 0), or names the
  table that lost rows (exit 1).
- It takes under a minute.
- Lines `Supabase-only, skipped: ...` name things only a Supabase project has (`pg_jsonschema`, the
  vault, the realtime publication). They are expected. Any other error fails the test.

Also look at the counts against the dashboard (Table Editor) once:

- `public.workout_library` = the library rows;
- `auth.users` = the number of accounts.

You can schedule it too: a second Task Scheduler task, user root, monthly (the 1st, 05:00), the same
command, with the email-on-error setting.

## 8. Before any change to the database: a backup by hand

Before applying a migration, running a data fix or deleting rows:

1. Run the backup task by hand: Task Scheduler → select **Rx Lab database backup** → **Run**.
2. Check `backup.log` ends with `OK` and note the name, e.g. `rxlab_20261120-151500`.
3. Keep that night from the 14-day cleanup by renaming its three files with `keep_` in front.
   As root:

   ```sh
   cd /volume1/RxLabBackup
   for f in rxlab_20261120-151500_*.sql; do mv "$f" "keep_$f"; done
   ```

   The cleanup only deletes files whose name starts with `rxlab_`.
4. Restore-test that set:

   ```sh
   bash /volume1/@rxlab/synology_restore_test.sh /volume1/RxLabBackup keep_rxlab_20261120-151500
   ```

5. Only then change the database. Write the backup's name in the PR or issue.
6. Delete `keep_` sets you no longer need by hand.

Undoing a change: use the change's own rollback script first (for example
`supabase/rollback/20261118_backend_v2_rollback.sql`). The backup is the last resort.

## 9. Restore into Supabase (disaster: the project is lost or broken)

This is Supabase's own documented restore, into a **new** project, run from the NAS as root.

1. Create the new project (database.new) on Postgres 17.
2. Write its connection details into a second service file, as in step 3, with the section
   `[restore]` instead of `[rxlab]`:

   ```sh
   umask 077; cat > /volume1/@rxlab/restore.conf      # [restore] then host=..., user=..., password=..., sslmode=require
   ```

3. Load roles, then schema, then data, in one transaction. All or nothing: if any line fails, nothing
   is changed.

   ```sh
   B=/backup/rxlab_20261120-030001      # the night to restore (or keep_rxlab_...)
   /usr/local/bin/docker run --rm -v /volume1/RxLabBackup:/backup:ro \
     -v /volume1/@rxlab/restore.conf:/s.conf:ro -e PGSERVICEFILE=/s.conf -e PGSERVICE=restore \
     postgres:17-alpine psql --single-transaction --variable ON_ERROR_STOP=1 \
       --file "${B}_roles.sql" --file "${B}_schema.sql" \
       --command 'SET session_replication_role = replica' --file "${B}_data.sql"
   ```

   The order matters: the app's tables refer to `auth.users`, and the schema must exist before its
   data. `session_replication_role = replica` loads rows without firing triggers, as Supabase's
   guide does.
4. Check the counts (step 7, or the Table Editor).
5. Then, outside the database:
   - Point the app at the new project. Its URL and keys change: a new app build.
   - Set up Auth again: Apple sign-in, email settings, redirect URLs.
   - Copy the Storage files.
   - Users sign in again: their old sessions are not valid in the new project.
6. Delete `/volume1/@rxlab/restore.conf`.

## Tested

Tested on 19 Nov 2026, in a Linux container with Docker and `postgres:17-alpine` (pg_dump 17.12).

**The source** was a local Supabase Postgres 17.11, set up like live:
- build 17's backend migrations applied;
- the 38 library rows;
- 2,518 synthetic drafts;
- synthetic users;
- 200 storage objects;
- the uploads migration's 4 storage policies.

| Test | Result |
|---|---|
| A nightly backup | Three files, about 1.3 MB, under a second. |
| Supabase's documented restore (step 9) into a new Supabase Postgres 17.11 | psql ended without one error. The result equalled the source on every check: rows of the library, drafts, gyms, `auth.users`, storage objects and buckets; all 20 policies, including the 4 on `storage.objects`; table, column and function grants; triggers; RLS flags; constraints; the automatic grants; `pg_jsonschema`. |
| The monthly restore test (step 7) | Every row of 15 tables. |
| A cut-off file | Refused. |
| Wrong password, Supabase down, a dump stopped part-way, a dump over its time limit, a second run during a run | Each exits with an error, leaves no file and deletes no older backup. |
| A password in the error text | Replaced by `***` in the log and the email. |
| The 14-night cleanup | Correct with three files a night. |
| `keep_` sets | Never deleted. |

## What has not been tested on the NAS itself

| Not tested | What could go wrong |
|---|---|
| DSM 7.2.2's Task Scheduler running the command as root | Paths, `bash` |
| DSM's `stat`, `find` and `docker` (Container Manager) | Different versions from the test machine |
| A real Session pooler connection from the home network | It needs TLS (`sslmode=require`) |
| File Station showing `backup.log` | It should, the log is 644 |
| `chmod 600` under `/volume1/@rxlab` | It should stick, outside the share's permissions |
| Hyper Backup, Snapshot Replication and the Recycle Bin settings | Not tested at all |

The first manual run (step 5) and the first restore test (step 7) check all of these. If one fails,
the log line says which check stopped it.
