-- Rollback for 20260919120000_add_bulk_import_upload_history.sql
--
-- WARNING: dropping the table discards the upload history. Storage objects in
-- the bucket are NOT deleted here (a bucket with objects cannot be dropped);
-- download anything you need first, then empty the bucket from the dashboard
-- if you really want it gone.

begin;

drop policy if exists bulk_import_uploads_admin_select on storage.objects;
drop policy if exists bulk_import_uploads_admin_insert on storage.objects;

drop table if exists public.bulk_import_uploads;

commit;
