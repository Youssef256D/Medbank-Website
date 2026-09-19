-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

create sequence if not exists public.platform_course_code_seq as bigint start 1;

create or replace function private.next_platform_course_code(p_name text)
returns text
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  letters text;
  prefix text;
begin
  letters := upper(regexp_replace(coalesce(p_name, ''), '[^a-zA-Z]', '', 'g'));
  prefix := case
    when length(letters) = 0 then 'MED'
    else rpad(left(letters, 3), 3, 'X')
  end;
  return prefix || '-'
    || lpad(nextval('public.platform_course_code_seq')::text, 4, '0');
end;
$$;

create or replace function private.set_platform_course_code()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.course_code is null or btrim(new.course_code) = '' then
    new.course_code := private.next_platform_course_code(new.course_name);
  else
    new.course_code := btrim(new.course_code);
  end if;
  return new;
end;
$$;

drop trigger if exists platform_courses_set_code on public.platform_courses;
create trigger platform_courses_set_code
before insert or update on public.platform_courses
for each row execute function private.set_platform_course_code();

update public.platform_courses
set course_code = null
where course_code is null
   or btrim(course_code) !~ '^[A-Z]{3}-[0-9]{4}$';

create unique index if not exists platform_courses_course_code_uniq
on public.platform_courses (upper(course_code))
where course_code is not null and btrim(course_code) <> '';
