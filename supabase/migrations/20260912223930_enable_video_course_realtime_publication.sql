-- Enable Realtime for the Video Course (LMS) tables and the site feature flags.
--
-- Why: the website had no realtime signal for any platform_* table, so a newly
-- published course/module/lesson, a granted enrolment, or a flipped site flag
-- only reached a student after a manual refresh or a re-login. The MCQ side has
-- had realtime since 20260404110000; this brings the LMS side to parity.
--
-- This migration is PUBLICATION MEMBERSHIP ONLY. It creates no policy, alters
-- no policy, and touches no access-gating column. Realtime still evaluates the
-- existing RLS policies per subscriber for every change, so adding a table here
-- cannot widen what any user is able to read.
--
-- Deliberately EXCLUDED, do not "complete the set":
--   * platform_course_coupons and platform_course_coupon_modules
--       RLS is enabled with ZERO policies (verified on the hosted project) —
--       a deliberate deny-all, because coupon codes are hash-only and are
--       redeemed exclusively through redeem_platform_course_coupon().
--       Publishing them would emit change traffic for rows nobody may select.
--   * platform_course_coupon_redemptions
--       Redemption is a deliberate user action; the client already knows.
--   * platform_lesson_progress
--       Written by the student's own device. Adding it is pure fan-out for a
--       value the writing client already has.
--   * platform_course_suggestions
--       Admin-side triage, no student-facing liveness requirement.

do $$
declare
  target_table text;
  realtime_tables constant text[] := array[
    'platform_courses',
    'platform_course_modules',
    'platform_course_lessons',
    'platform_course_resources',
    'platform_course_enrollments',
    'platform_course_module_entitlements',
    'platform_course_announcements',
    'platform_course_enrollment_requests',
    'app_feature_flags'
  ];
begin
  foreach target_table in array realtime_tables loop
    -- Skip tables that do not exist on this project rather than failing the
    -- whole migration; the platform_* set has changed shape before.
    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = target_table
        and c.relkind = 'r'
    ) then
      raise notice 'skipping %: table does not exist', target_table;
      continue;
    end if;

    if exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = target_table
    ) then
      raise notice 'skipping %: already in supabase_realtime', target_table;
      continue;
    end if;

    execute format(
      'alter publication supabase_realtime add table public.%I',
      target_table
    );
    raise notice 'added % to supabase_realtime', target_table;
  end loop;
end
$$;
