-- Workout library: workouts the app can run without an app update (docs/WORKOUT_LIBRARY.md).
-- One row per workout; `definition` is the WorkoutDefinition JSON exactly as BarPathKit encodes
-- it (the phone decodes it and sends it to the watch like any phone-picked workout).
--
-- v1: only the project owner adds rows (dashboard SQL editor / service role, see
-- tools/library/make_row.py). Signed-in users can read published shared rows.
-- Later: `owner` holds a user id for private workouts (e.g. imported from a paid program),
-- readable only by that user. Nothing writes `owner` yet.

create table public.workout_library (
  id text primary key,                 -- = definition.id, "lib.<program>.<yyyymmdd>.<slug>"
  definition jsonb not null,           -- WorkoutDefinition JSON (BarPathKit's Codable form)
  program text,                        -- "Mayhem", "Blue Republic", "Benchmark", "HYROX", …
  scheduled_on date,                   -- the day it is programmed (null = any day)
  published boolean not null default true,
  owner uuid references auth.users (id) on delete cascade,  -- null = shared library
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- The watch keys a workout by definition.id: the row id must be the same string.
  constraint workout_library_id_matches check (definition ->> 'id' = id)
);

create index workout_library_scheduled_on_idx on public.workout_library (scheduled_on);

alter table public.workout_library enable row level security;

-- Explicit, so it works when "Automatically expose new tables" is off. Read only: there are no
-- insert/update/delete grants or policies; the owner writes with the dashboard (service role).
grant select on public.workout_library to authenticated;

create policy "Signed-in users read published workouts" on public.workout_library
  for select to authenticated
  using (published and (owner is null or owner = (select auth.uid())));

-- updated_at follows every change (the app shows the newest version of an id).
create function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger workout_library_touch before update on public.workout_library
  for each row execute function public.touch_updated_at();
