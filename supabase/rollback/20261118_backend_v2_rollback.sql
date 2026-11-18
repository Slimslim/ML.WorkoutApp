-- Rollback of 20261118000100_workout_library_v2.sql and 20261118000000_workout_drafts.sql
-- (#70). Not a migration: run by hand (dashboard SQL editor), only if the Data chat's checks
-- after applying fail. One transaction: all or nothing. Tested by supabase/tests/run.sh.
--
-- What it does: removes the legacy copies of v2 rows, drops the v2 tables (rows, revisions,
-- custom scales are lost: export them first if any real ones exist), and moves the drafts back
-- into workout_library with published = false and their original timestamps. It refuses to run
-- when workout_drafts holds rows that did not come from the library (later imports/syncs).
begin;

do $$
begin
  if exists (select 1 from public.workout_drafts where source <> 'library') then
    raise exception 'rollback: workout_drafts holds rows that did not come from the library; export them and decide first';
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

-- 2. drafts back into the library (reverse of 20261118000000)
alter table public.workout_library drop constraint workout_library_no_drafts;
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
drop table public.workout_drafts;
drop function public.is_project_admin();
drop table public.project_admins;

commit;
