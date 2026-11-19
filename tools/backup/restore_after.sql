-- Restore into a NEW Supabase project, step 2 of 2: run after both pg_restore commands.
-- Supabase's defaults back for objects created later (as a new project has them).
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant execute on functions to public;
