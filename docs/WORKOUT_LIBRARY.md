# Workout library (workouts in the database)

New workouts reach the app **without an app update**: they are rows in the Supabase table
`workout_library` (migration `supabase/migrations/20261104000000_workout_library.sql`). The phone
fetches them, shows them in **Workouts → Choose**, and sends the one you pick to the watch
exactly like a built-in workout. User stories: W8–W10 in `docs/USER_STORIES.md`.

v1: **only the owner adds workouts.** Signed-in users can read published shared rows; nobody can
write from the app.

## One-time setup

1. Supabase dashboard → SQL editor → paste the whole migration file
   `supabase/migrations/20261104000000_workout_library.sql` → Run.
2. Paste `tools/library/seed/seed.sql` → Run (adds two invented example workouts, "Seesaw" and a
   power C&J EMOM).
3. On the phone: Workouts → Choose → pull down. The two workouts appear under "Example".

## Add a workout

1. Write the workout as JSON in `tools/library/seed/<name>.json` (copy one of the seed files):

   ```json
   {
     "program": "Mayhem",
     "scheduled_on": "2026-11-05",
     "published": true,
     "definition": { "id": "lib.mayhem.20261105.chipper", "name": "…", "shortName": "…", … }
   }
   ```

   A bare definition (just the `definition` object) works too; give `--program` / `--date` then.
   To publish a built-in under a library id:
   `python3 tools/library/make_row.py --builtin wod.helen --id lib.benchmark.20261110.helen --program Benchmark --date 2026-11-10`.
2. `python3 tools/library/make_row.py tools/library/seed/<name>.json` prints the SQL. It refuses a
   definition the app would not decode the same way (misspelled or missing keys, unknown kind /
   unit / format, a built-in id, a bad id).
3. Dashboard → SQL editor → paste → Run. It is an upsert: running it again updates the row.
4. Phone: pull down in Choose (it also refreshes when the Workouts tab opens or the app comes to
   the foreground, at most once a minute).

Later, Claude with database access can run the same SQL. Keep the JSON in the repo only for
invented examples or public benchmarks (see Privacy); the seed files are invented workouts. Keep `seed.sql` in sync:
`python3 tools/library/make_row.py tools/library/seed/*.json > tools/library/seed/seed.sql`
(a test checks it).

To hide a workout: `update public.workout_library set published = false where id = '…';`
(phones drop it on their next refresh). Deleting the row works the same way.

## Who sees what (migration `20261110000000_gyms.sql`)

| Row | Seen by | Written by |
|---|---|---|
| Gym programming (`gym_id` set) | every member of that gym (`gym_members`), on their schedule | the project owner (SQL editor / service role); later coaches |
| Personal workout (`owner` set) | only that user | that user (the app, later) or the owner for them |
| Public (both null) | every signed-in user | the project owner; only benchmarks (Helen, HYROX, ...) |

Recordings and results (`uploads`) are always private to their user. Gym members are added by the
owner for now: `insert into public.gym_members (gym_id, user_id) values ('blue-republic', '<user id>');`
(the user id is the user's folder name in the `uploads` bucket, or `auth.users.id`). A new gym:
`insert into public.gyms (id, name) values ('<slug>', '<Name>');`. Gym rows from a file: add
`"gym": "<slug>"` to the JSON or pass `--gym <slug>` to `tools/library/make_row.py`.
Gym programming is the gym's work: it stays out of this repo (the database only).

Personal rows during the beta: the owner enters each tester's program with `--owner <user id>`
(or `"owner": "<user id>"` in the JSON). A row has an owner or a gym, never both. The upsert only
updates a row that already has the same owner, so one tester can never overwrite another's:

```
python3 tools/library/make_row.py --builtin wod.helen --id lib.benchmark.20261110.helen.u1a2b3c4d \
    --program Benchmark --date 2026-11-10 --owner 1a2b3c4d-5e6f-4a1b-8c2d-0123456789ab
```

## Fields

| Column | Meaning |
|---|---|
| `id` | Primary key, the same string as `definition.id` (a check constraint enforces it). |
| `definition` | `jsonb`, the WorkoutDefinition JSON exactly as BarPathKit encodes it (`id`, `name`, `shortName`, `format` forTime/amrap/emom, `team` solo/doubles/team, `healthKitActivity`, `segments`, optional `timeCapSeconds`, `intervalSeconds`, `roundSize`). Segment: `kind` run/station/transition/rest, `movement`, `name`, optional `target` {`value`, `unit` meters/reps/calories/seconds}, optional `load` {`value`, `unit` lb/kg, `count`}. |
| `program` | Section title in Choose: "Mayhem", "Blue Republic", "Benchmark", "HYROX", … (null → "Library"). |
| `scheduled_on` | The day it is programmed. Today's (phone calendar) go into the "Today" section at the top; the others are listed newest first with their date. Null = undated. |
| `published` | false hides it from the app. |
| `owner` | A user id: that user's **personal** workout, seen only by them. Null otherwise. |
| `gym_id` | A gym id (`gyms.id`, e.g. `blue-republic`): that gym's **programming**, seen by its members. Null otherwise. A row has an owner or a gym, never both; neither = public (benchmarks). |
| `created_at`, `updated_at` | Set by the database (`updated_at` follows every change). |

## Id convention

`lib.<program>.<yyyymmdd>.<slug>`: lowercase letters, digits and `-`, e.g.
`lib.mayhem.20261105.chipper`, `lib.example.20261101.seesaw`. Undated workouts may skip the
date (`lib.benchmark.helen`).

Personal rows (`owner` set) end with `.u<first 8 hex characters of the owner id, lowercase>`,
e.g. `lib.mayhem.20261105.chipper.u1a2b3c4d`: ids are global, so two testers with the same
program, date and slug must not share one. `make_row.py` refuses an owner row without that
suffix and names the id it expects. The app never splits an id, so the extra segment is harmless.

Ids must never be a built-in id (`hyrox.solo`, `wod.helen`, …): for a built-in id the watch
always runs its own built-in version (`WorkoutSessionModel.selectedDefinition`), and the phone
skips such rows. Changing a row keeps its id, so past results find the new version (Fix splits →
"Use the current version"). A workout that is really different gets a new id.

## How it reaches the watch

`WorkoutLibraryStore` (phone) fetches published rows while signed in and keeps the last good
list in Application Support (not Documents, which is uploaded). Signed out or offline, Choose
shows that cached list. A row whose definition does not decode is skipped and listed under
"Library rows not shown". Send to watch uses `PhoneLink.sendWorkout(definition)`: the full
definition travels in the `selectWorkout` application context, so the watch needs no network and
no update; it keeps the definition for START. Results carry their definition, so History and the
workout report work even after the row is removed.

## Privacy and copyright

The repo is public and the shared library is readable by every signed-in user. Programs people
pay for (Mayhem, Blue Republic, gym class programming) are the program's work: in v1 the shared
library is for the owner's own testing. When users can add workouts (the AI parser), their
workouts are **private rows** (`owner` = their user id, readable only by them, already allowed by
the select policy) and never copied into the shared library or into this repo. Only
benchmark/public workouts (Helen, HYROX, Murph…) belong in the shared library.

## Build 17: drafts table and the v2 library (#70)

Migrations `20261118000000_workout_drafts.sql` and `20261118000100_workout_library_v2.sql`
(docs/WORKOUT_MODEL_RFC.md 7.2 and 14.3 F). Nothing changes for builds 15/16: they read
`workout_library` as before.

| Table | Holds | Read by | Written by |
|---|---|---|---|
| `workout_drafts` | drafts (schemaVersion 0, imports, synced programming before it is published); the 2,518 unpublished library rows moved here | the project owner (`project_admins`); a user only their own drafts | service role only (for now) |
| `workout_library_v2` | schemaVersion 2 workouts (`schemas/workout-definition.v2.schema.json`) | same rule as `workout_library` (public / gym members / owner) | `make_row.py`, the import; users only their personal rows (id suffix checked) |
| `workout_library_v2_revisions` | every revision of a v2 definition | whoever can read the workout | the database |
| `workout_library` | the 29 legacy rows + the **legacy copies** of v2 rows | builds 15/16 and later | the database for v2 ids (legacy copy); otherwise as before |
| `workout_custom_scales` | an athlete's own "Mine" scale per workout (`based_on_revision`) | that user | that user |

- **One writer.** `make_row.py` writes a `"schemaVersion": 2` file to `workout_library_v2` only.
  The database copies the old keys (`id`, `name`, `shortName`, `format`, `team`,
  `healthKitActivity`, `segments`, `timeCapSeconds`, `intervalSeconds`, `roundSize`) into
  `workout_library` **only when the row is published and every scale is `fidelity: "exact"`**,
  and removes the copy otherwise. A direct write to a copy is refused; to hide or change a v2
  workout, change its v2 row. A v2 row can't take the id of one of the 29 legacy rows (their
  migration is build 17 item 5).
- **Schema checks in the database.** `pg_jsonschema` refuses a v2 row that fails the schema (and
  rows over 64 KB). The schema is open outside the engine fields, so unknown keys (`resume`,
  `interrupt`, `x-*`, `note`) are stored unchanged. A schema change = edit the repo file + a new
  migration that replaces `public.workout_definition_v2_schema()`; a test fails while they differ.
- **Revisions.** `revision` goes up only when `definition` changes. To roll back, write an old
  definition again (it becomes a new revision):
  `update public.workout_library_v2 v set definition = r.definition from public.workout_library_v2_revisions r where v.id = '<id>' and r.workout_id = v.id and r.revision = <n>;`
- **Paging.** The API returns at most 1,000 rows. Page with
  `rpc/workout_library_v2_page` (`after_id` = last id of the previous page, `page_size` ≤ 1000),
  or `order=id&id=gt.<last id>&limit=…` on the table.
- **Only flat definitions in the library:** `workout_library` refuses `schemaVersion` 0 (drafts)
  and 2 (v2 rows go to `workout_library_v2`). Personal rows written with a user's token now need
  the id suffix there too (no one can take an id the owner or a draft uses).
- `make_row.py` keeps a v2 row's gym when re-run without `--gym` (as for flat rows); a user can
  still read, change and delete their own unpublished v2 rows. Its v2 upsert raises when it would
  write nothing (the id belongs to another owner or audience) instead of reporting success.
- **Until the compiler exists (build 17 item 2), "exact" is the author's word.** `make_row.py`
  refuses a published, exact v2 row (its old keys go to builds 15/16) unless `--trust-old-keys`
  is given, after the old keys were checked against the structure by hand.
- **Changing the schema later:** the CHECK calls `workout_definition_v2_schema()`. A stricter
  schema must come with a data migration that checks every existing row first; otherwise those
  rows fail every later update and a `pg_dump` restore.
- Notes for the migration of the 29 rows (item 5): the 3 personal ids without the suffix can no
  longer be changed with a user token (the owner's service role still can). Deleting the owner's
  account deletes their drafts (`on delete cascade`), now the only copy: back them up first.
- Tests: `tools/tests/test_workout_library_v2.py` (make_row, schema copy) and
  `supabase/tests/run.sh` (the migrations on a throwaway `supabase/postgres` database: RLS,
  schema refusal, legacy copy, revisions, paging, the 29 rows untouched, rollback). CI runs both.

### Applying it (Data chat, after the PR is merged)

Never from CI. In the dashboard SQL editor (or the Supabase MCP), in this order:

1. **Before (read only):**
   ```sql
   select published, count(*) from public.workout_library group by 1;          -- expect true 29, false 2518
   select count(*) from public.workout_library where published and definition ->> 'schemaVersion' = '0';  -- expect 0
   select md5(string_agg(t::text, '|' order by t.id)) from public.workout_library t where published;      -- note it
   select name, installed_version from pg_available_extensions where name = 'pg_jsonschema';             -- available
   select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_jsonschema';  -- none or 'extensions' (the migration calls extensions.jsonb_matches_schema)
   select count(*) from public.workout_library where coalesce(definition ->> 'schemaVersion', '1') not in ('1', '0');  -- 0
   select count(distinct owner) from public.workout_library where not published and owner is not null;  -- 1 (the owner)
   select to_regclass('public.workout_drafts'), to_regclass('public.workout_library_v2'), to_regclass('public.project_admins');  -- all null
   ```
   Also export `select * from public.workout_library` to the owner's private storage (never the
   repo) as a backup.
2. **Apply** `20261118000000_workout_drafts.sql`, then `20261118000100_workout_library_v2.sql`,
   each as one transaction: the SQL editor, `apply_migration`, `supabase db push` or `psql -1 -f`,
   **never plain `psql -f`**. The first checks itself and raises if the move is incomplete or a
   published row changed; its NOTICE says `moved 2518 drafts; published rows unchanged`. Both set
   `lock_timeout = 5s`: on a lock timeout, just run the file again. If the second file fails, the
   first stays applied and the apps are unaffected: fix the cause (usually `pg_jsonschema`) and
   run the second file again. Then add the owner, without committing the id:
   `insert into public.project_admins (user_id) values ('<owner user id>');`
3. **After (read only):**
   ```sql
   select count(*), count(*) filter (where source = 'library' and moved_at is not null) from public.workout_drafts;  -- 2518, 2518
   select count(*) from public.project_admins;                                     -- 1
   select published, count(*) from public.workout_library group by 1;              -- true 29 only
   select md5(string_agg(t::text, '|' order by t.id)) from public.workout_library t where published;  -- same as before
   select count(*) from public.workout_library_v2;                                 -- 0
   select extensions.jsonb_matches_schema(public.workout_definition_v2_schema(), '{}'::jsonb);  -- false
   ```
   As a tester (or with the "impersonate" role in the dashboard): `workout_drafts` returns 0
   rows; as the owner, 2518. On a build-15/16 phone: Workouts → Choose shows the same list as
   before.
4. **Rollback** (only if a check fails, or a build-15/16 phone shows a different list):
   `supabase/rollback/20261118_backend_v2_rollback.sql`, one run. It also works when only the
   first file was applied. It removes the v2 tables and legacy copies and puts the drafts back with
   `published = false` and their timestamps; it refuses if `workout_drafts` holds rows that did
   not come from the library, or a draft id is now used in the library, and it checks the
   published rows are unchanged. Then mark the two versions reverted in the migration history if
   they were recorded there: `supabase migration repair --status reverted 20261118000000 20261118000100`.
