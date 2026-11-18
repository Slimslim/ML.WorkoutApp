-- Build 17, item 1 (#70, docs/WORKOUT_MODEL_RFC.md 7.2.1 and 14.3 F1): drafts leave the library.
--
-- Today every unpublished row of workout_library is a draft (the owner's private program and the
-- partner gym's class programming, schemaVersion 0 + scales). Only `published = false` hides
-- them. This migration moves them, unchanged, into `workout_drafts`, which only the project owner
-- reads (plus, later, a user their own imported drafts). Published rows are not touched (D5): the
-- apps of builds 15/16 read `workout_library` exactly as before and never saw these rows.
--
-- Rollback: supabase/rollback/20261118_backend_v2_rollback.sql.

-- Project admins: the user ids that count as "the owner" for owner-only tables. Filled once by
-- hand (dashboard / service role), never from the repo (no ids in the public repo):
--   insert into public.project_admins (user_id) values ('<owner user id>');
create table public.project_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.project_admins enable row level security;
-- No policies and no grants: not readable through the API. The function below reads it.
revoke all on public.project_admins from anon, authenticated;
grant select, insert, update, delete on public.project_admins to service_role;

create function public.is_project_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.project_admins a where a.user_id = (select auth.uid()));
$$;
revoke execute on function public.is_project_admin() from public, anon;
grant execute on function public.is_project_admin() to authenticated, service_role;

create table public.workout_drafts (
  id text primary key,                  -- = definition.id
  definition jsonb not null,            -- any draft shape (schemaVersion 0, scales, rawText, ...)
  program text,
  scheduled_on date,
  owner uuid references auth.users (id) on delete cascade,     -- whose draft (null = the owner's gym/program work)
  gym_id text references public.gyms (id) on delete restrict,  -- the gym it was programmed for
  source text not null default 'library',  -- 'library' = moved here on 18 Nov; later 'import', 'sync'
  moved_at timestamptz,                  -- set for rows moved out of workout_library
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workout_drafts_id_matches check (definition ->> 'id' = id),
  constraint workout_drafts_one_audience check (owner is null or gym_id is null)
);
create index workout_drafts_scheduled_on_idx on public.workout_drafts (scheduled_on);
create index workout_drafts_gym_idx on public.workout_drafts (gym_id);
create index workout_drafts_owner_idx on public.workout_drafts (owner);

alter table public.workout_drafts enable row level security;
-- Read only through the API; the owner writes with the service role (dashboard, scripts).
-- Revoke first: Supabase's default privileges may grant everything on new tables.
revoke all on public.workout_drafts from anon, authenticated;
grant select on public.workout_drafts to authenticated;
grant select, insert, update, delete on public.workout_drafts to service_role;

-- The project owner reads every draft; any other user only drafts that are theirs (none today).
-- Gym members never see gym drafts: those are not programming yet.
create policy "Owner reads all drafts, users their own" on public.workout_drafts
  for select to authenticated
  using ((select public.is_project_admin()) or owner = (select auth.uid()));

create trigger workout_drafts_touch before update on public.workout_drafts
  for each row execute function public.touch_updated_at();

-- Move the drafts. Checked in the same transaction: every unpublished row arrives, and the
-- published rows are exactly the same before and after (count and content).
do $$
declare
  n_drafts integer;
  n_moved integer;
  published_before text;
  published_after text;
begin
  -- No write may slip in between counting, copying and deleting.
  lock table public.workout_library in share row exclusive mode;
  select count(*) into n_drafts from public.workout_library where not published;
  select coalesce(md5(string_agg(t::text, '|' order by t.id)), '')
    into published_before from public.workout_library t where t.published;

  -- One statement: exactly the rows deleted are the rows inserted.
  with moved as (
    delete from public.workout_library where not published
    returning id, definition, program, scheduled_on, owner, gym_id, created_at, updated_at
  )
  insert into public.workout_drafts
    (id, definition, program, scheduled_on, owner, gym_id, source, moved_at, created_at, updated_at)
  select id, definition, program, scheduled_on, owner, gym_id, 'library', now(), created_at, updated_at
  from moved;
  get diagnostics n_moved = row_count;

  select coalesce(md5(string_agg(t::text, '|' order by t.id)), '')
    into published_after from public.workout_library t;
  if n_moved <> n_drafts then
    raise exception 'workout_drafts: moved % rows, expected %', n_moved, n_drafts;
  end if;
  if published_after <> published_before then
    raise exception 'workout_drafts: the published rows changed';
  end if;
  raise notice 'workout_drafts: moved % drafts; published rows unchanged', n_moved;
end;
$$;

-- From now on the library takes only today's flat definitions (schemaVersion absent or 1): drafts
-- (0) land in workout_drafts (#70), v2 rows in workout_library_v2, whose legacy copies carry no
-- schemaVersion. NOT VALID: existing rows are not re-checked (D5).
alter table public.workout_library
  add constraint workout_library_v1_only check (coalesce(definition ->> 'schemaVersion', '1') = '1') not valid;
