-- Rollback for 20261013180000_user_course_locks.sql: restores the previous
-- private.can_current_user_access_question body and drops both lock tables.

create or replace function private.can_current_user_access_question(target_course_id uuid, target_topic_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.user_course_enrollments e
    join public.courses enrolled_course on enrolled_course.id = e.course_id
    join public.courses question_course on question_course.id = target_course_id
    join public.course_topics question_topic on question_topic.id = target_topic_id
    where e.user_id = (select auth.uid())
      and enrolled_course.is_active is true
      and question_course.is_active is true
      and question_topic.is_active is true
      and question_topic.course_id = question_course.id
      and enrolled_course.academic_year = question_course.academic_year
      and enrolled_course.academic_semester = question_course.academic_semester
      and (
        enrolled_course.id = question_course.id
        or (
          private.course_code_key(enrolled_course.course_code) <> ''
          and private.course_code_key(enrolled_course.course_code)
            = private.course_code_key(question_course.course_code)
        )
        or private.course_name_key(enrolled_course.course_name)
          = private.course_name_key(question_course.course_name)
      )
  );
$function$;

alter publication supabase_realtime drop table public.course_locks, public.user_course_locks;
drop table if exists public.user_course_locks;
drop table if exists public.course_locks;
