-- After supabase/rollback/20261118_backend_v2_rollback.sql: the library is exactly as before the
-- migrations (29 published rows and 2,518 drafts, every column), and the new tables are gone.
select test_harness.ok(not exists (
  ((select * from test_harness.published_before union all select * from test_harness.drafts_before)
   except select * from public.workout_library)
  union all
  (select * from public.workout_library
   except (select * from test_harness.published_before union all select * from test_harness.drafts_before))),
  'rollback: workout_library equals the pre-migration snapshot (29 published + 2518 drafts)');
select test_harness.ok(to_regclass('public.workout_drafts') is null and to_regclass('public.workout_library_v2') is null
  and to_regclass('public.workout_custom_scales') is null and to_regclass('public.project_admins') is null,
  'rollback: the new tables are gone');
