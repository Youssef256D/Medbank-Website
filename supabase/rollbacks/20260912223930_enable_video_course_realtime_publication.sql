-- Rollback for 20260913090000_enable_video_course_realtime_publication.sql
--
-- Removes the Video Course (LMS) tables and the site feature flags from the
-- supabase_realtime publication, returning them to poll-only delivery.
--
-- Safe to run: publication membership only. No policy, no grant, no column.
-- The frontend degrades to its existing refresh paths if these are removed.

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
    if exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = target_table
    ) then
      execute format(
        'alter publication supabase_realtime drop table public.%I',
        target_table
      );
      raise notice 'removed % from supabase_realtime', target_table;
    end if;
  end loop;
end
$$;
