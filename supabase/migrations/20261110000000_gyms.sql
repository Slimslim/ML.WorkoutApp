-- Gyms (docs/WORKOUT_LIBRARY.md, "Who sees what"). Three kinds of rows in workout_library:
--   gym programming   gym_id set, owner null   -> every member of that gym (their schedule)
--   personal workout  owner set, gym_id null   -> only that user
--   public benchmark  both null                -> every signed-in user (Helen, HYROX, ...)
-- Recordings and results (uploads) were already private per user and do not change.
--
-- Gym programming is written by the project owner (dashboard SQL editor / service role);
-- members are added the same way for now (invite codes later). Users may create, change and
-- delete only their own personal workouts.

create table public.gyms (
  id text primary key,                  -- slug, e.g. 'blue-republic'
  name text not null,                   -- 'Blue Republic CrossFit'
  created_at timestamptz not null default now(),
  constraint gyms_id_slug check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

create table public.gym_members (
  gym_id text not null references public.gyms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'member',  -- 'member' (later: 'coach')
  created_at timestamptz not null default now(),
  primary key (gym_id, user_id)
);
create index gym_members_user_idx on public.gym_members (user_id);

alter table public.workout_library
  add column gym_id text references public.gyms (id) on delete restrict;
alter table public.workout_library
  add constraint workout_library_one_audience check (owner is null or gym_id is null);
create index workout_library_gym_idx on public.workout_library (gym_id);

alter table public.gyms enable row level security;
alter table public.gym_members enable row level security;
grant select on public.gyms, public.gym_members to authenticated;

-- A user sees their own memberships and the gyms they belong to.
create policy "Users read their own memberships" on public.gym_members
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Users read their gyms" on public.gyms
  for select to authenticated
  using (id in (select gym_id from public.gym_members where user_id = (select auth.uid())));

-- Reading the library: own personal rows, rows of the user's gyms, public rows.
drop policy "Signed-in users read published workouts" on public.workout_library;
create policy "Users read their own, their gyms' and public workouts" on public.workout_library
  for select to authenticated
  using (
    published and (
      owner = (select auth.uid())
      or (owner is null and gym_id is null)
      or gym_id in (select gym_id from public.gym_members where user_id = (select auth.uid()))
    )
  );

-- Personal workouts: a user writes only rows that are theirs and not a gym's.
grant insert, update, delete on public.workout_library to authenticated;
create policy "Users add their own workouts" on public.workout_library
  for insert to authenticated with check (owner = (select auth.uid()) and gym_id is null);
create policy "Users change their own workouts" on public.workout_library
  for update to authenticated
  using (owner = (select auth.uid()))
  with check (owner = (select auth.uid()) and gym_id is null);
create policy "Users delete their own workouts" on public.workout_library
  for delete to authenticated using (owner = (select auth.uid()));

-- The service role (dashboard, scripts) keeps full access, as for workout_library.
grant select, insert, update, delete on public.gyms, public.gym_members to service_role;
