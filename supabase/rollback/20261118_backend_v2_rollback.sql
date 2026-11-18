-- Rollback of 20261118000100_workout_library_v2.sql and 20261118000000_workout_drafts.sql
-- (#70). Not a migration: run by hand (dashboard SQL editor), only if the Data chat's checks
-- after applying fail. One transaction: all or nothing. Tested by supabase/tests/run.sh.
--
-- What it does: removes the legacy copies of v2 rows, drops the v2 tables (rows, revisions,
-- custom scales are lost: export them first if any real ones exist), and moves the drafts back
-- into workout_library with published = false and their original timestamps. It refuses to run
-- when workout_drafts holds rows that did not come from the library (later imports/syncs), or
-- when a draft's id was taken in workout_library meanwhile. It checks the published legacy rows
-- (all but the v2 copies) are unchanged.
--
-- If the migrations were recorded in supabase_migrations.schema_migrations (applied with
-- `supabase db push` or the MCP apply_migration), mark them reverted afterwards, or a later push
-- skips them: `supabase migration repair --status reverted 20261118000000 20261118000100`
-- (or delete those two rows from supabase_migrations.schema_migrations).
begin;

create temp table rollback_published_before on commit drop as
  select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) as h
  from public.workout_library t
  where t.published and not exists (select 1 from public.workout_library_v2 v where v.id = t.id);

do $$
begin
  if exists (select 1 from public.workout_drafts where source <> 'library') then
    raise exception 'rollback: workout_drafts holds rows that did not come from the library; export them and decide first';
  end if;
  if exists (select 1 from public.workout_drafts d join public.workout_library l using (id)) then
    raise exception 'rollback: % draft ids are now used in workout_library; resolve them first',
      (select count(*) from public.workout_drafts d join public.workout_library l using (id));
  end if;
end;
$$;

-- 1. v2 (reverse of 20261118000100)
delete from public.workout_library l using public.workout_library_v2 v where l.id = v.id;
drop trigger workout_library_guard_v2 on public.workout_library;
drop function public.workout_library_guard_v2();
drop table public.workout_custom_scales;
drop function public.workout_library_v2_page(text, integer);
drop table public.workout_library_v2_revisions;
drop table public.workout_library_v2;
drop function public.workout_v2_before_write();
drop function public.workout_v2_after_write();
drop function public.workout_v2_legacy_definition(jsonb);
drop function public.workout_custom_scale_schema();
drop function public.workout_definition_v2_schema();
-- pg_jsonschema stays installed (harmless; other objects may use it).

-- The legacy write policies as the gyms migration made them.
drop policy "Users add their own workouts" on public.workout_library;
create policy "Users add their own workouts" on public.workout_library
  for insert to authenticated with check (owner = (select auth.uid()) and gym_id is null);
drop policy "Users change their own workouts" on public.workout_library;
create policy "Users change their own workouts" on public.workout_library
  for update to authenticated
  using (owner = (select auth.uid()))
  with check (owner = (select auth.uid()) and gym_id is null);

-- 2. drafts back into the library (reverse of 20261118000000)
alter table public.workout_library drop constraint workout_library_v1_only;
do $$
declare n_drafts integer; n_back integer;
begin
  select count(*) into n_drafts from public.workout_drafts;
  insert into public.workout_library (id, definition, program, scheduled_on, published, owner, gym_id, created_at, updated_at)
  select id, definition, program, scheduled_on, false, owner, gym_id, created_at, updated_at
  from public.workout_drafts;
  get diagnostics n_back = row_count;
  if n_back <> n_drafts then
    raise exception 'rollback: moved back % drafts, expected %', n_back, n_drafts;
  end if;
  raise notice 'rollback: % drafts back in workout_library (published = false)', n_back;
end;
$$;
do $$
begin
  if (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.workout_library t where t.published)
     <> (select h from rollback_published_before) then
    raise exception 'rollback: the published rows changed';
  end if;
end;
$$;
drop table public.workout_drafts;
drop function public.is_project_admin();
drop table public.project_admins;

commit;
