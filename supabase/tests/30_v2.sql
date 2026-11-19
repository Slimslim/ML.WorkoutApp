-- After tools/library/make_row.py wrote tools/library/fixtures/v2/valid/*.json (run.sh).

-- make_row wrote v2 rows, and the legacy copy exists only for published all-exact rows.
select test_harness.ok((select count(*) from public.workout_library_v2) = 6, 'make_row: 6 fixture rows in workout_library_v2');
select test_harness.ok((select bool_and(revision = 1) from public.workout_library_v2)
  and (select count(*) from public.workout_library_v2_revisions) = 6,
  'make_row: running the same SQL twice (an upsert of exact rows with copies) changes no revision');
select test_harness.ok(
  (select array_agg(id order by id) from public.workout_library where id like 'lib.test.%')
  = array['lib.test.20261118.all-exact', 'lib.test.20261118.exact-emom', 'lib.test.20261118.mine.u00000000'],
  'legacy copy: only the exact rows (exact-emom, all-exact scales, exact personal)');
select test_harness.ok(not exists (select 1 from public.workout_library where id in
  ('lib.test.20261118.mixed', 'lib.test.20261118.future', 'lib.test.20261118.text-only')),
  'legacy copy: none for approx, textOnly or mixed scales');

-- The copy holds only the old keys, and they equal the v2 row's old keys.
select test_harness.ok(not exists (
  select 1 from public.workout_library l join public.workout_library_v2 v using (id)
  where exists (select 1 from jsonb_object_keys(l.definition) k
                where k not in ('id','name','shortName','format','team','healthKitActivity','segments','timeCapSeconds','intervalSeconds','roundSize'))
     or l.definition -> 'segments' is distinct from v.definition -> 'segments'
     or l.definition ->> 'format' is distinct from v.definition ->> 'format'
     or l.program is distinct from v.program or l.owner is distinct from v.owner or l.gym_id is distinct from v.gym_id
     or not l.published), 'legacy copy: old keys only, same audience as the v2 row');

-- Unknown future fields pass through unchanged.
select test_harness.ok(
  (select definition #> '{structure,body,1,repeat,resume}' from public.workout_library_v2 where id = 'lib.test.20261118.future') = '"min"'
  and (select definition #> '{structure,body,1,repeat,body,0,part,interrupt,every}' from public.workout_library_v2 where id = 'lib.test.20261118.future') = '240'
  and (select definition -> 'x-futureRoot' from public.workout_library_v2 where id = 'lib.test.20261118.future') = '{"anything": [1, 2.5, "three", null]}'
  and (select definition -> 'requires' from public.workout_library_v2 where id = 'lib.test.20261118.future') = '["interrupt", "resume"]',
  'pass-through: resume, interrupt, x-* and requires are stored unchanged');

-- Schema refusal (the database, not only make_row).
select test_harness.fails($$insert into public.workout_library_v2 (id, definition)
  select 'lib.test.20261118.bad', jsonb_set(definition, '{id}', '"lib.test.20261118.bad"') #- '{structure,body,0,repeat,body,0,timed,body,0,part,id}'
  from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom'$$,
  'schema: a part without an id is refused', 'workout_library_v2_schema');
select test_harness.fails($$insert into public.workout_library_v2 (id, definition)
  values ('lib.test.20261118.v1', '{"id": "lib.test.20261118.v1", "name": "x", "shortName": "x", "format": "forTime", "team": "solo", "healthKitActivity": "x", "segments": []}')$$,
  'schema: a definition without schemaVersion 2 is refused');
select test_harness.fails($$update public.workout_library_v2 set definition = jsonb_set(definition, '{fidelity}', '"close"')
  where id = 'lib.test.20261118.exact-emom'$$, 'schema: an update to an invalid definition is refused', 'workout_library_v2_schema');
select test_harness.fails($$insert into public.workout_library_v2 (id, definition)
  select 'lib.test.20261118.big', jsonb_set(jsonb_set(definition, '{id}', '"lib.test.20261118.big"'), '{rawText}', to_jsonb(repeat('x', 70000)))
  from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom'$$, 'size: a definition over 64 KB is refused', 'workout_library_v2_size');
select test_harness.fails($$insert into public.workout_library_v2 (id, definition)
  select 'lib.gym.20261101.wod', jsonb_set(definition, '{id}', '"lib.gym.20261101.wod"')
  from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom'$$,
  'one writer: a v2 row cannot take the id of a legacy row', 'already used by a legacy library row');
select test_harness.fails($$update public.workout_library set program = 'hand edit' where id = 'lib.test.20261118.exact-emom'$$,
  'one writer: a legacy copy cannot be written directly', 'is a v2 workout');
select set_config('app.workout_v2_sync', 'on', false);
select test_harness.fails($$update public.workout_library set program = 'hand edit' where id = 'lib.test.20261118.exact-emom'$$,
  'one writer: no setting turns the guard off', 'is a v2 workout');
select test_harness.fails($$insert into public.workout_library (id, definition) values ('lib.test.20261118.mixed',
  '{"id": "lib.test.20261118.mixed", "name": "x", "shortName": "x", "format": "forTime", "team": "solo", "healthKitActivity": "x", "segments": []}')$$,
  'one writer: nobody adds a legacy row for a non-exact v2 id', 'is a v2 workout');

-- Revisions: bumped only when the definition changes; every revision kept; rollback = new revision.
select test_harness.ok((select revision from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom') = 1, 'revision: starts at 1');
update public.workout_library_v2 set program = 'Renamed', revision = 99 where id = 'lib.test.20261118.exact-emom';
select test_harness.ok((select revision from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom') = 1,
                       'revision: unchanged when only program changes (and the writer cannot set it)');
select test_harness.ok((select program from public.workout_library where id = 'lib.test.20261118.exact-emom') = 'Renamed', 'legacy copy follows program');
update public.workout_library_v2 set definition = jsonb_set(definition, '{name}', '"Every 1:00 x 4: Squats"') where id = 'lib.test.20261118.exact-emom';
select test_harness.ok((select revision from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom') = 2, 'revision: 2 after a definition change');
select test_harness.ok((select definition ->> 'name' from public.workout_library where id = 'lib.test.20261118.exact-emom') = 'Every 1:00 x 4: Squats',
                       'legacy copy follows the definition');
update public.workout_library_v2 v set definition = r.definition
  from public.workout_library_v2_revisions r
  where v.id = 'lib.test.20261118.exact-emom' and r.workout_id = v.id and r.revision = 1;
select test_harness.ok((select revision from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom') = 3
  and (select count(*) from public.workout_library_v2_revisions where workout_id = 'lib.test.20261118.exact-emom') = 3,
  'revision: a rollback to revision 1 is revision 3; history keeps 1, 2, 3');

-- Exact -> approx removes the copy; approx -> exact adds it; unpublished removes it; delete removes it.
update public.workout_library_v2 set definition = jsonb_set(jsonb_set(definition, '{fidelity}', '"approx"'), '{approx}', '["test"]')
  where id = 'lib.test.20261118.exact-emom';
select test_harness.ok(not exists (select 1 from public.workout_library where id = 'lib.test.20261118.exact-emom'), 'legacy copy: removed when the row becomes approx');
update public.workout_library_v2 set definition = jsonb_set(definition #- '{approx}', '{fidelity}', '"exact"') where id = 'lib.test.20261118.exact-emom';
select test_harness.ok(exists (select 1 from public.workout_library where id = 'lib.test.20261118.exact-emom'), 'legacy copy: back when the row is exact again');
update public.workout_library_v2 set published = false where id = 'lib.test.20261118.exact-emom';
select test_harness.ok(not exists (select 1 from public.workout_library where id = 'lib.test.20261118.exact-emom'), 'legacy copy: removed when unpublished');
update public.workout_library_v2 set published = true where id = 'lib.test.20261118.exact-emom';
update public.workout_library_v2 set definition = jsonb_set(definition, '{scales,1,fidelity}', '"exact"') where id = 'lib.test.20261118.mixed';
select test_harness.ok(exists (select 1 from public.workout_library where id = 'lib.test.20261118.mixed' and gym_id = 'test-gym'),
                       'legacy copy: appears when the last scale becomes exact');
delete from public.workout_library_v2 where id = 'lib.test.20261118.mixed';
select test_harness.ok(not exists (select 1 from public.workout_library where id = 'lib.test.20261118.mixed')
  and not exists (select 1 from public.workout_library_v2_revisions where workout_id = 'lib.test.20261118.mixed'),
  'delete: the copy and the history go with the row');

-- RLS on v2 rows, revisions and personal writes.
set role authenticated;
select test_harness.login('0000000c-0000-4000-8000-00000000000c');
select test_harness.ok((select array_agg(id order by id) from public.workout_library_v2)
  = array['lib.test.20261118.exact-emom', 'lib.test.20261118.future', 'lib.test.20261118.text-only'],
  'RLS v2: a non-member reads only the public rows');
select test_harness.ok((select count(*) from public.workout_library_v2_revisions where workout_id like 'lib.test.20261118.all-exact%') = 0,
  'RLS v2: no revisions of a gym row for a non-member');
select test_harness.fails($$insert into public.workout_library_v2 (id, definition, owner)
  select 'lib.test.20261118.mine.u00000000x', definition, '00000000-0000-4000-8000-000000000001' from public.workout_library_v2 limit 1$$,
  'RLS v2: a user cannot write a row owned by someone else');
select test_harness.login('00000000-0000-4000-8000-000000000001');
select test_harness.ok((select count(*) from public.workout_library_v2) = 5, 'RLS v2: a tester reads public, gym and own rows');
select test_harness.ok((select count(*) from public.workout_library_v2_revisions where workout_id = 'lib.test.20261118.all-exact') = 1,
                       'RLS v2: a gym member reads the gym row''s revisions');
-- A tester writes a personal v2 row (own id suffix) and gets the legacy copy for it.
insert into public.workout_library_v2 (id, definition, program, owner)
  select 'lib.test.20261118.own.u00000000', jsonb_set(definition, '{id}', '"lib.test.20261118.own.u00000000"'), 'Mine', '00000000-0000-4000-8000-000000000001'
  from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom';
select test_harness.ok((select count(*) from public.workout_library where id = 'lib.test.20261118.own.u00000000') = 1,
                       'personal: the user''s exact row gets a legacy copy they can read');
select test_harness.fails($$insert into public.workout_library_v2 (id, definition, owner)
  select 'lib.test.20261118.nosuffix', jsonb_set(definition, '{id}', '"lib.test.20261118.nosuffix"'), '00000000-0000-4000-8000-000000000001'
  from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom'$$,
  'personal: an id without the user suffix is refused', 'workout_library_v2_owner_suffix');
select test_harness.fails($$update public.workout_library_v2 set revision = 7 where id = 'lib.test.20261118.own.u00000000'$$,
  'grants: a user cannot write revision', 'permission denied');
select test_harness.fails($$update public.workout_library_v2 set gym_id = 'test-gym' where id = 'lib.test.20261118.own.u00000000'$$,
  'grants: a user cannot move a row to a gym', 'permission denied');
select test_harness.fails($$insert into public.workout_library_v2 (id, definition)
  select 'lib.test.20261118.pub2', jsonb_set(definition, '{id}', '"lib.test.20261118.pub2"') from public.workout_library_v2 where id = 'lib.test.20261118.exact-emom'$$,
  'RLS v2: a user cannot add a public row');
do $$
declare n integer;
begin
  update public.workout_library_v2 set program = 'x' where id = 'lib.test.20261118.exact-emom';
  get diagnostics n = row_count;
  perform test_harness.ok(n = 0, 'RLS v2: a user cannot change a public row');
end;
$$;
-- Their own unpublished row stays readable, changeable and deletable by them (and has no copy).
update public.workout_library_v2 set published = false where id = 'lib.test.20261118.own.u00000000';
select test_harness.ok(not exists (select 1 from public.workout_library where id = 'lib.test.20261118.own.u00000000'),
                       'personal: unpublishing removes the copy');
do $$
declare n integer;
begin
  update public.workout_library_v2 set program = 'Still mine' where id = 'lib.test.20261118.own.u00000000';
  get diagnostics n = row_count;
  perform test_harness.ok(n = 1, 'personal: a user changes their own unpublished row');
end;
$$;
select test_harness.ok((select count(*) from public.workout_library_v2_revisions where workout_id = 'lib.test.20261118.own.u00000000') = 1,
                       'personal: a user reads the revisions of their unpublished row');
delete from public.workout_library_v2 where id = 'lib.test.20261118.own.u00000000';
select test_harness.ok(not exists (select 1 from public.workout_library where id = 'lib.test.20261118.own.u00000000'),
                       'personal: deleting the row deletes its copy');

-- Custom scales: user-only, schema-checked.
insert into public.workout_custom_scales (workout_id, scale, based_on_revision)
  select 'lib.test.20261118.all-exact',
         (definition -> 'scales' -> 1) || '{"id": "custom", "label": "Mine", "short": "Mine", "basedOn": "l1"}', revision
  from public.workout_library_v2 where id = 'lib.test.20261118.all-exact';
select test_harness.ok((select count(*) from public.workout_custom_scales) = 1, 'custom scale: the tester adds and reads their own');
insert into public.workout_custom_scales (workout_id, scale)
  values ('lib.test.20261118.exact-emom', '{"id": "custom", "label": "Mine", "basedOn": "rx", "structure": {"body": [{"part": {"id": "sq", "movement": "airSquats", "target": {"value": 8, "unit": "reps"}}}]}}');
select test_harness.ok((select count(*) from public.workout_custom_scales) = 2, 'custom scale: the RFC 3.6 shape (no rank, no fidelity) is accepted');
select test_harness.fails($$insert into public.workout_custom_scales (workout_id, scale)
  values ('lib.test.20261118.future', '{"id": "custom", "label": "Mine", "rank": 1, "fidelity": "exact", "structure": {"body": []}}')$$,
  'custom scale: an invalid scale is refused', 'workout_custom_scales_schema');
select test_harness.fails($$insert into public.workout_custom_scales (user_id, workout_id, scale)
  select '0000000a-0000-4000-8000-00000000000a', 'lib.test.x', scale from public.workout_custom_scales limit 1$$,
  'custom scale: a user cannot write someone else''s');
select test_harness.login('0000000c-0000-4000-8000-00000000000c');
select test_harness.ok((select count(*) from public.workout_custom_scales) = 0, 'custom scale: another user reads none');
reset role;

-- Paging: 1,200 more public rows; a user pages through all of them, 500 then 1000 at a time.
insert into public.workout_library_v2 (id, definition, program)
select 'lib.page.' || lpad(n::text, 4, '0') || '.w', jsonb_set(definition, '{id}', to_jsonb('lib.page.' || lpad(n::text, 4, '0') || '.w')), 'Paging'
from public.workout_library_v2, generate_series(1, 1200) n where id = 'lib.test.20261118.text-only';
set role authenticated;
select test_harness.login('0000000c-0000-4000-8000-00000000000c');
do $$
declare
  last_id text := null; total integer := 0; got integer; pages integer := 0; size integer;
begin
  foreach size in array array[500, 1000] loop
    last_id := null; total := 0; pages := 0;
    loop
      select count(*), max(id) into got, last_id from public.workout_library_v2_page(last_id, size) p;
      exit when got = 0;
      total := total + got; pages := pages + 1;
      exit when got < size;
    end loop;
    perform test_harness.ok(total = 1203, format('paging: %s rows in %s pages of %s', total, pages, size));
  end loop;
  perform test_harness.ok((select count(*) from public.workout_library_v2_page(null, 5000)) = 1000, 'paging: a page holds at most 1000 rows');
end;
$$;
reset role;

-- D5 again, at the end: the 29 published rows are still exactly as before.
select test_harness.ok(not exists (
  select * from test_harness.published_before
  except select l.* from public.workout_library l join test_harness.published_before b using (id)),
  'D5: the 29 published rows are unchanged after all v2 writes');

-- Deleting an account (in-app "Delete account") still works and takes the user's v2 rows,
-- their legacy copies and their custom scales with it.
delete from auth.users where id = '00000000-0000-4000-8000-000000000001';
select test_harness.ok(not exists (select 1 from public.workout_library_v2 where owner = '00000000-0000-4000-8000-000000000001')
  and not exists (select 1 from public.workout_library where id = 'lib.test.20261118.mine.u00000000')
  and not exists (select 1 from public.workout_custom_scales), 'delete account: v2 rows, copies and custom scales go with the user');

-- N3: the schema helpers, trigger functions and admin check are not callable by anon (Supabase
-- grants execute on new functions to PUBLIC by default; the migrations revoke it).
select test_harness.ok(not exists (
    select 1 from unnest(array[
      'public.workout_definition_v2_schema()', 'public.workout_custom_scale_schema()',
      'public.workout_v2_legacy_definition(jsonb)', 'public.workout_v2_before_write()',
      'public.workout_v2_after_write()', 'public.workout_library_guard_v2()',
      'public.workout_library_v2_page(text, integer)', 'public.is_project_admin()']) f
    where has_function_privilege('anon', f, 'execute')),
  'grants: anon has no execute on the v2 helpers, trigger functions, paging and is_project_admin');
select test_harness.ok(not exists (
    select 1 from unnest(array['public.workout_v2_before_write()', 'public.workout_v2_after_write()',
                               'public.workout_library_guard_v2()']) f
    where has_function_privilege('authenticated', f, 'execute')),
  'grants: signed-in users have no execute on the trigger functions');
set role anon;
select test_harness.fails($$select public.workout_definition_v2_schema()$$,
                          'grants: anon calling a schema helper is refused', 'permission denied');
reset role;
