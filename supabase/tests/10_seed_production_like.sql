-- A synthetic stand-in for production before the migration (no real content, ids or users):
-- 29 published rows (20 gym, 9 personal, 3 of them without the id suffix) and 2,518 drafts
-- (schemaVersion 0, scales, rawText; owner-private and gym), one of them about 16.5 KB.
--   owner  0000000a-0000-4000-8000-00000000000a  project owner (admin), gym member
--   tester 00000000-0000-4000-8000-000000000001  gym member (also the owner of fixture exact_personal)
--   other  0000000c-0000-4000-8000-00000000000c  signed in, no gym
insert into auth.users (id, aud, role, email) values
  ('0000000a-0000-4000-8000-00000000000a', 'authenticated', 'authenticated', 'owner@example.invalid'),
  ('00000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'tester@example.invalid'),
  ('0000000c-0000-4000-8000-00000000000c', 'authenticated', 'authenticated', 'other@example.invalid');

insert into public.gyms (id, name) values ('test-gym', 'Test Gym');
insert into public.gym_members (gym_id, user_id) values
  ('test-gym', '0000000a-0000-4000-8000-00000000000a'),
  ('test-gym', '00000000-0000-4000-8000-000000000001');

create function pg_temp.legacy_def(id text, n integer) returns jsonb language sql as $$
  select jsonb_build_object(
    'id', id, 'name', 'Synthetic ' || n, 'shortName', 'Syn ' || n, 'format', 'forTime',
    'team', 'solo', 'healthKitActivity', 'crossTraining', 'timeCapSeconds', 600.0,
    'segments', jsonb_build_array(
      jsonb_build_object('kind', 'station', 'movement', 'burpees', 'name', 'Burpees',
                         'target', jsonb_build_object('value', 10 + n, 'unit', 'reps'))));
$$;

-- 20 gym rows
insert into public.workout_library (id, definition, program, scheduled_on, published, gym_id)
select 'lib.gym.202611' || lpad(n::text, 2, '0') || '.wod', pg_temp.legacy_def('lib.gym.202611' || lpad(n::text, 2, '0') || '.wod', n),
       'Test Gym', date '2026-11-01' + n, true, 'test-gym'
from generate_series(1, 20) n;
-- 9 personal rows: 6 with the suffix, 3 without (as in production)
insert into public.workout_library (id, definition, program, scheduled_on, published, owner)
select i, pg_temp.legacy_def(i, n), 'Personal', null, true, o
from (
  select n,
         case when n <= 6 then 'lib.mine.p' || n || '.u0000000a' else 'lib.mine.p' || n end as i,
         '0000000a-0000-4000-8000-00000000000a'::uuid as o
  from generate_series(1, 9) n
) s;

-- 2,518 drafts: 1,800 owner-private, 718 gym. One large one (~16.5 KB).
insert into public.workout_library (id, definition, program, scheduled_on, published, owner, gym_id)
select i,
       jsonb_build_object('schemaVersion', 0, 'id', i, 'name', 'Draft ' || n,
         'scales', jsonb_build_array(
            jsonb_build_object('id', 'rx', 'label', 'Rx', 'rawText', repeat('synthetic text ', case when n = 7 then 1100 else 3 end)),
            jsonb_build_object('id', 'l2', 'label', 'Level 2', 'rawText', 'synthetic')),
         'x-draftField', n),
       case when n <= 1800 then 'Paid program' else 'Test Gym' end,
       date '2025-04-01' + (n % 500), false,
       case when n <= 1800 then '0000000a-0000-4000-8000-00000000000a'::uuid end,
       case when n > 1800 then 'test-gym' end
from (select n, 'lib.draft.' || n || case when n <= 1800 then '.u0000000a' else '' end as i
      from generate_series(1, 2518) n) s;

-- Snapshots to compare with after the migration.
create table test_harness.published_before as select * from public.workout_library where published;
create table test_harness.drafts_before as select * from public.workout_library where not published;
select test_harness.ok((select count(*) from test_harness.published_before) = 29, 'seed: 29 published rows');
select test_harness.ok((select count(*) from test_harness.drafts_before) = 2518, 'seed: 2518 drafts');
select test_harness.ok((select max(octet_length(definition::text)) from test_harness.drafts_before) between 16000 and 17500,
                       'seed: largest draft about 16.5 KB');
