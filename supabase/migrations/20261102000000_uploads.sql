-- Rx Lab test version: every file the phone stores (lifts, workouts, watch recordings) is
-- uploaded to the private Storage bucket "uploads" under "<user id>/<path on the phone>",
-- with one row per file here. Each user can only see and change their own rows and files.
-- The project owner reads everything with the service role (dashboard / scripts).

create table public.uploads (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  path text not null,               -- object path in the bucket, starts with the user id
  kind text not null,               -- "lifts", "workouts" or "debug" (first folder on the phone)
  bytes integer not null,
  file_modified_at timestamptz,
  uploaded_at timestamptz not null default now(),
  unique (user_id, path)
);

create index uploads_kind_idx on public.uploads (kind, uploaded_at);

alter table public.uploads enable row level security;

create policy "Users read their own uploads" on public.uploads
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users add their own uploads" on public.uploads
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update their own uploads" on public.uploads
  for update to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- uploaded_at follows re-uploads (upsert of a changed file).
create function public.touch_uploaded_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.uploaded_at := now();
  return new;
end;
$$;
create trigger uploads_touch before update on public.uploads
  for each row execute function public.touch_uploaded_at();

-- Storage: private bucket, 50 MB per file (full-session CSVs are the largest).
insert into storage.buckets (id, name, public, file_size_limit)
values ('uploads', 'uploads', false, 52428800)
on conflict (id) do nothing;

create policy "Users read their own files" on storage.objects
  for select to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users add their own files" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users replace their own files" on storage.objects
  for update to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users delete their own files" on storage.objects
  for delete to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- In-app "Delete account": the app removes the files first, then calls this.
-- Deleting the auth user also deletes the uploads rows (on delete cascade).
create function public.delete_user() returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from auth.users where id = auth.uid();
end;
$$;
revoke execute on function public.delete_user() from public, anon;
grant execute on function public.delete_user() to authenticated;
