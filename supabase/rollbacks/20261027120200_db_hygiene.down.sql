-- Rollback for 20261027120200_db_hygiene.sql. Rows already removed by the
-- two crons are not restored.

select cron.unschedule(jobid) from cron.job
where jobname in ('prune-cron-run-details', 'purge-deleted-accounts-archive');

update storage.buckets
set file_size_limit = null, allowed_mime_types = null
where id = 'popup-images';

alter table public.platform_course_coupons
  drop constraint platform_course_coupons_disabled_by_fkey,
  add constraint platform_course_coupons_disabled_by_fkey
    foreign key (disabled_by) references public.profiles (id) on delete restrict;
alter table public.platform_course_coupons
  drop constraint platform_course_coupons_created_by_fkey,
  add constraint platform_course_coupons_created_by_fkey
    foreign key (created_by) references public.profiles (id) on delete restrict;
-- Fails if a coupon lost its creator in the meantime; fill created_by first.
alter table public.platform_course_coupons
  alter column created_by set not null;

alter table private.question_change_log
  drop constraint if exists question_change_log_pkey;

create index if not exists idx_profiles_role_approved
  on public.profiles (role, approved);
create index if not exists idx_profiles_role_approved_mcq
  on public.profiles (role, approved, mcq_access_enabled);

drop index if exists public.question_reports_resolved_by_idx;
