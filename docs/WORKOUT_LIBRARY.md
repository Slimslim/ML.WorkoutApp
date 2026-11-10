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
2. Paste `tools/library/seed/seed.sql` → Run (adds Freedom and the power C&J EMOM).
3. On the phone: Workouts → Choose → pull down. The two workouts appear under "PitFIRE".

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
the owner's own or public workouts (see Privacy). Keep `seed.sql` in sync:
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
`lib.mayhem.20261105.chipper`, `lib.pitfire.20261102.freedom`. Undated workouts may skip the
date (`lib.benchmark.helen`).

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
