-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- platform_resources_select_student_visible required lesson_id IS NOT NULL, so a
-- resource attached to a MODULE ("Chapter materials", which the app's lesson screen
-- explicitly renders) or to the course as a whole was withheld from every student.
-- One course-scoped row exists in production and has never been visible to anyone.
--
-- Each scope is now checked at its own level. Course-scoped material requires real
-- access to the course (an enrollment or any module entitlement) rather than mere
-- visibility of it -- a course-level PDF is paid content, not a prospectus.

create or replace function private.has_platform_course_access(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_courses c
      where c.id = target_course_id
        and c.is_active is true
        and c.is_published is true
        and (
          exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = c.id
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = c.id
          )
        )
    );
$function$;

drop policy if exists platform_resources_select_student_visible on public.platform_course_resources;

create policy platform_resources_select_student_visible
  on public.platform_course_resources
  for select
  to authenticated
  using (
    is_published is true
    and case
          when lesson_id is not null then private.can_access_platform_lesson(lesson_id)
          when module_id is not null then private.has_platform_module_access(module_id)
          else private.has_platform_course_access(course_id)
        end
  );
