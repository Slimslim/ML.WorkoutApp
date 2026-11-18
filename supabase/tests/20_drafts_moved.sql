-- After 20261118000000_workout_drafts.sql and 20261118000100_workout_library_v2.sql.
insert into public.project_admins (user_id) values ('0000000a-0000-4000-8000-00000000000a');

-- The drafts moved, unchanged.
select test_harness.ok((select count(*) from public.workout_drafts) = 2518, 'drafts: 2518 rows in workout_drafts');
select test_harness.ok((select count(*) from public.workout_library where not published) = 0, 'drafts: none left in workout_library');
select test_harness.ok(not exists (
  select b.id from test_harness.drafts_before b
  left join public.workout_drafts d using (id)
  where d.id is null or d.definition is distinct from b.definition or d.program is distinct from b.program
     or d.scheduled_on is distinct from b.scheduled_on or d.owner is distinct from b.owner
     or d.gym_id is distinct from b.gym_id or d.created_at is distinct from b.created_at
     or d.updated_at is distinct from b.updated_at), 'drafts: every draft moved with the same content and timestamps');

-- D5: the 29 published rows are exactly as before (every column).
select test_harness.ok((select count(*) from public.workout_library) = 29, 'D5: workout_library holds the 29 published rows');
select test_harness.ok(not exists (
  (select * from test_harness.published_before except select * from public.workout_library)
  union all
  (select * from public.workout_library except select * from test_harness.published_before)),
  'D5: the 29 published rows are unchanged (all columns)');

-- A draft can no longer be written into the library.
select test_harness.fails($$insert into public.workout_library (id, definition, published)
  values ('lib.x.20261118.draft', '{"schemaVersion": 0, "id": "lib.x.20261118.draft"}', false)$$,
  'library refuses a schemaVersion 0 draft', 'workout_library_v1_only');
select test_harness.fails($$insert into public.workout_library (id, definition)
  values ('lib.x.20261118.v2', '{"schemaVersion": 2, "id": "lib.x.20261118.v2"}')$$,
  'library refuses a schemaVersion 2 definition (v2 goes to workout_library_v2)', 'workout_library_v1_only');

-- RLS on drafts: the owner reads them all; a tester and another user read none.
set role authenticated;
select test_harness.login('0000000a-0000-4000-8000-00000000000a');
select test_harness.ok((select count(*) from public.workout_drafts) = 2518, 'RLS: the project owner reads all 2518 drafts');
select test_harness.login('00000000-0000-4000-8000-000000000001');
select test_harness.ok((select count(*) from public.workout_drafts) = 0, 'RLS: a tester (gym member) reads no drafts');
select test_harness.ok((select count(*) from public.workout_library where owner is not null and owner <> '00000000-0000-4000-8000-000000000001') = 0,
                       'RLS: a tester reads no owner-private library rows');
select test_harness.ok((select count(*) from public.workout_library) = 20, 'RLS: a tester reads the 20 gym rows, as before');
select test_harness.fails($$select count(*) from public.project_admins$$, 'RLS: project_admins is not readable');
select test_harness.fails($$update public.workout_drafts set program = 'x'$$, 'RLS: a tester cannot write drafts');
select test_harness.fails($$insert into public.workout_drafts (id, definition, owner) values ('lib.a.b.u00000000', '{"id": "lib.a.b.u00000000"}', '00000000-0000-4000-8000-000000000001')$$,
                          'RLS: a tester cannot add drafts');
-- Legacy personal writes need the id suffix now (no squatting on the owner's or a draft's ids).
select test_harness.fails($$insert into public.workout_library (id, definition, owner)
  values ('lib.draft.5.u0000000a', '{"id": "lib.draft.5.u0000000a", "name": "x", "shortName": "x", "format": "forTime", "team": "solo", "healthKitActivity": "x", "segments": []}',
          '00000000-0000-4000-8000-000000000001')$$, 'legacy: a user cannot take a draft''s id', 'row-level security');
select test_harness.fails($$insert into public.workout_library (id, definition, owner)
  values ('lib.hyrox.20261201.wod', '{"id": "lib.hyrox.20261201.wod", "name": "x", "shortName": "x", "format": "forTime", "team": "solo", "healthKitActivity": "x", "segments": []}',
          '00000000-0000-4000-8000-000000000001')$$, 'legacy: a user cannot take an id without their suffix', 'row-level security');
insert into public.workout_library (id, definition, owner)
  values ('lib.own.20261118.legacy.u00000000', '{"id": "lib.own.20261118.legacy.u00000000", "name": "x", "shortName": "x", "format": "forTime", "team": "solo", "healthKitActivity": "x", "segments": []}',
          '00000000-0000-4000-8000-000000000001');
delete from public.workout_library where id = 'lib.own.20261118.legacy.u00000000';
select test_harness.ok(true, 'legacy: a user still adds and deletes a personal row with their suffix');
select test_harness.login('0000000c-0000-4000-8000-00000000000c');
select test_harness.ok((select count(*) from public.workout_drafts) = 0, 'RLS: a signed-in non-member reads no drafts');
select test_harness.ok((select count(*) from public.workout_library) = 0, 'RLS: a non-member reads no library rows (none are public)');
reset role;
set role anon;
select test_harness.fails($$select count(*) from public.workout_drafts$$, 'RLS: anon cannot read drafts');
reset role;
