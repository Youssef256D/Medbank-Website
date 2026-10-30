-- Database hygiene from the 2026-10-26 audit. Each part is independent.
-- Rollback: supabase/rollbacks/20261027120200_db_hygiene.down.sql

-- 1) Index the one unindexed foreign key (performance advisor).
create index if not exists question_reports_resolved_by_idx
  on public.question_reports (resolved_by);

-- 2) Drop two never-used indexes on profiles; every profile write pays for
--    them. Access checks filter by id, not by role/approved.
drop index if exists public.idx_profiles_role_approved;
drop index if exists public.idx_profiles_role_approved_mcq;

-- 3) Give the question change log a primary key (performance advisor).
--    (version, question_id) is already unique and never null.
alter table private.question_change_log
  add constraint question_change_log_pkey primary key (version, question_id);

-- 4) Deleting an admin who created or disabled coupons failed (ON DELETE
--    RESTRICT). Keep the coupon, forget who made it.
alter table public.platform_course_coupons
  alter column created_by drop not null;
alter table public.platform_course_coupons
  drop constraint platform_course_coupons_created_by_fkey,
  add constraint platform_course_coupons_created_by_fkey
    foreign key (created_by) references public.profiles (id) on delete set null;
alter table public.platform_course_coupons
  drop constraint platform_course_coupons_disabled_by_fkey,
  add constraint platform_course_coupons_disabled_by_fkey
    foreign key (disabled_by) references public.profiles (id) on delete set null;

-- 5) popup-images had no size or type limit. Current files are PNG, the
--    largest 1.1 MB.
update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp', 'image/gif']
where id = 'popup-images';

-- 6) Housekeeping crons.
--    cron.job_run_details grows forever (59 MB; three jobs, two every 5 min).
--    archive.deleted_accounts: docs/legal/deletion.md promises deleted-account
--    records are kept at most 90 days.
do $$
declare
  v_jobid bigint;
begin
  for v_jobid in
    select jobid from cron.job
    where jobname in ('prune-cron-run-details', 'purge-deleted-accounts-archive')
  loop
    perform cron.unschedule(v_jobid);
  end loop;
end;
$$;

select cron.schedule(
  'prune-cron-run-details',
  '41 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '14 days'$$
);

select cron.schedule(
  'purge-deleted-accounts-archive',
  '47 3 * * *',
  $$delete from archive.deleted_accounts where deleted_at < now() - interval '90 days'$$
);
