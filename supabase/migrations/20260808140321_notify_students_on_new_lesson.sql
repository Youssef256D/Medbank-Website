-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

create or replace function private.notify_students_on_new_lesson()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  course public.platform_courses%rowtype;
  module_title text;
  module_published boolean;
  instructor text;
  external_prefix text;
begin
  if new.is_published is not true then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.is_published is true then
    return new;
  end if;

  select * into course
  from public.platform_courses c
  where c.id = new.course_id;

  if not found
     or course.is_active is not true
     or course.is_published is not true
     or course.review_status is distinct from 'approved' then
    return new;
  end if;

  select m.title, m.is_published
    into module_title, module_published
  from public.platform_course_modules m
  where m.id = new.module_id;

  if module_published is not true then
    return new;
  end if;

  external_prefix :=
    'lesson-added::' || new.course_id::text || '::' || new.id::text || '::';

  if exists (
    select 1 from public.notifications n
    where n.external_id like external_prefix || '%'
  ) then
    return new;
  end if;

  select coalesce(
           nullif(btrim(coalesce(p.full_name, '')), ''),
           nullif(btrim(coalesce(course.instructor_name, '')), '')
         )
    into instructor
  from public.profiles p
  where p.id = course.owner_id;

  insert into public.notifications (
    external_id,
    recipient_user_id,
    title,
    message,
    target_route,
    target_video_course_id,
    created_by,
    created_by_name
  )
  select
    external_prefix || gen_random_uuid()::text,
    student.user_id,
    'New lesson in ' || coalesce(nullif(btrim(course.course_name), ''), 'your course'),
    case
      when instructor is not null then
        instructor || ' added "' || new.title || '"'
      else
        'A new lesson, "' || new.title || '", was added'
    end
    || case
         when nullif(btrim(coalesce(module_title, '')), '') is not null
           then ' to ' || module_title
         else ''
       end
    || '. Tap to watch it.',
    'video-courses',
    new.course_id,
    course.owner_id,
    instructor
  from (
    select e.user_id
    from public.platform_course_enrollments e
    where e.course_id = new.course_id
      and e.access_scope = 'full'
    union
    select me.user_id
    from public.platform_course_module_entitlements me
    where me.course_id = new.course_id
      and me.module_id = new.module_id
  ) as student;

  return new;
end;
$$;

revoke all on function private.notify_students_on_new_lesson() from public;

drop trigger if exists notify_students_on_new_lesson
  on public.platform_course_lessons;

create trigger notify_students_on_new_lesson
after insert or update of is_published on public.platform_course_lessons
for each row
execute function private.notify_students_on_new_lesson();

create index if not exists notifications_external_id_prefix_idx
  on public.notifications (external_id text_pattern_ops);
