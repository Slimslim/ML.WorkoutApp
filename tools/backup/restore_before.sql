-- Restore into a NEW Supabase project, step 1 of 2 (docs/BACKUP.md, "Restore into Supabase").
-- Run in the new project's SQL editor before pg_restore.
create extension if not exists pg_jsonschema with schema extensions;
-- New objects get no automatic grants while the dump is restored: the dump's own GRANTs then
-- give exactly the privileges the backed-up database had.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke execute on functions from public;
