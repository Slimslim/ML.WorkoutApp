-- tools/library/seed/seed.sql (the invented example workouts in docs/WORKOUT_LIBRARY.md) on the
-- v2 schema: run.sh applies it twice (an upsert), then these checks; the rows are removed again
-- so the rollback check below still compares against the pre-migration snapshot.
select test_harness.ok((select count(*) from public.workout_library where id like 'lib.example.%') = 2,
                       'library seed: 2 example rows in workout_library (seed.sql twice = an upsert)');
select test_harness.ok(not exists (
    select 1 from public.workout_library
    where id like 'lib.example.%'
      and not (published and program = 'Example' and owner is null and gym_id is null
               and definition ->> 'id' = id and definition ->> 'schemaVersion' is null)),
  'library seed: public, published, flat definitions under "Example"');
select test_harness.ok(not exists (select 1 from public.workout_library_v2 where id like 'lib.example.%'),
                       'library seed: nothing written to workout_library_v2');

set role authenticated;
select test_harness.login('0000000c-0000-4000-8000-00000000000c');
select test_harness.ok((select count(*) from public.workout_library where id like 'lib.example.%') = 2,
                       'library seed: a signed-in user with no gym reads both rows');
reset role;

delete from public.workout_library where id like 'lib.example.%';
select test_harness.ok(not exists (select 1 from public.workout_library where id like 'lib.example.%'),
                       'library seed: example rows removed again');
