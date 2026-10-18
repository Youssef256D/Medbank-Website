-- Signed-out visitors cannot read public.courses (courses_select only allows
-- admins and enrolled students), so the signup and complete-profile forms
-- fell back to the hardcoded curriculum in main.js and showed course names
-- that had since been renamed. This read-only function returns just the name
-- and term of every ACTIVE course so those forms can show the live list.
-- It exposes no ids, topics, questions or inactive rows, and changes no RLS.

create or replace function public.get_signup_course_catalog()
returns table (
  course_name text,
  academic_year integer,
  academic_semester integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    trim(c.course_name)::text,
    c.academic_year::integer,
    c.academic_semester::integer
  from public.courses c
  where c.is_active is true
    and coalesce(trim(c.course_name), '') <> ''
    and c.academic_year between 1 and 5
    and c.academic_semester between 1 and 2
  order by c.academic_year, c.academic_semester, c.course_name;
$$;

revoke all on function public.get_signup_course_catalog() from public;
grant execute on function public.get_signup_course_catalog() to anon, authenticated;
