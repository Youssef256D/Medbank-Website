-- Bulk import upload history.
--
-- Every file (or pasted text) that a bulk import successfully publishes is kept
-- in a private Storage bucket and recorded in public.bulk_import_uploads, so an
-- admin can download the exact original again from the Bulk Import page.
--
-- Admin-only by construction: the bucket is private, and every policy below is
-- gated on private.is_admin_user(). Students and anon have no read path.
--
-- Append-only on purpose: there is no UPDATE or DELETE policy on the table or
-- the objects. This is a record of what was uploaded; losing the source files
-- is exactly the failure this exists to prevent (2026-09-19: the GIT and
-- Nephrology banks could not be restored because no source was kept).
--
-- Additive only: no existing table, policy, or gating column is touched.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'bulk-import-uploads',
  'bulk-import-uploads',
  false,
  52428800,
  array['text/csv', 'application/json', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists bulk_import_uploads_admin_select on storage.objects;
drop policy if exists bulk_import_uploads_admin_insert on storage.objects;

create policy bulk_import_uploads_admin_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'bulk-import-uploads'
  and (select private.is_admin_user())
);

create policy bulk_import_uploads_admin_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'bulk-import-uploads'
  and (select private.is_admin_user())
);

create table if not exists public.bulk_import_uploads (
  id uuid primary key default gen_random_uuid(),
  file_name text not null check (char_length(file_name) between 1 and 300),
  storage_path text not null unique,
  file_size bigint not null default 0 check (file_size >= 0),
  content_type text not null default 'text/csv',
  source text not null default 'file' check (source in ('file', 'pasted')),
  default_course text,
  default_topic text,
  import_as_draft boolean not null default false,
  rows_total integer not null default 0 check (rows_total >= 0),
  rows_added integer not null default 0 check (rows_added >= 0),
  error_count integer not null default 0 check (error_count >= 0),
  uploaded_by uuid references public.profiles(id) on delete set null default auth.uid(),
  uploaded_by_name text,
  created_at timestamptz not null default now()
);

comment on table public.bulk_import_uploads is
  'Append-only history of bulk-import source files. Originals live in the private bulk-import-uploads bucket at storage_path. Admin-only.';

create index if not exists bulk_import_uploads_created_at_idx
  on public.bulk_import_uploads (created_at desc);
create index if not exists bulk_import_uploads_uploaded_by_idx
  on public.bulk_import_uploads (uploaded_by);

alter table public.bulk_import_uploads enable row level security;

revoke all on public.bulk_import_uploads from anon;
grant select, insert on public.bulk_import_uploads to authenticated;

drop policy if exists bulk_import_uploads_admin_select on public.bulk_import_uploads;
drop policy if exists bulk_import_uploads_admin_insert on public.bulk_import_uploads;

create policy bulk_import_uploads_admin_select
on public.bulk_import_uploads
for select
to authenticated
using ((select private.is_admin_user()));

create policy bulk_import_uploads_admin_insert
on public.bulk_import_uploads
for insert
to authenticated
with check ((select private.is_admin_user()));

commit;
