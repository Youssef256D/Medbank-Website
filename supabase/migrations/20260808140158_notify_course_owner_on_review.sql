-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

create or replace function private.notify_course_owner_on_review()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  reviewer_name text;
  course_label text;
  note text;
begin
  if new.owner_id is null
     or new.review_status is not distinct from old.review_status
     or new.review_status not in ('approved', 'rejected') then
    return new;
  end if;

  select nullif(btrim(coalesce(p.full_name, '')), '')
    into reviewer_name
  from public.profiles p
  where p.id = new.reviewed_by;

  course_label := coalesce(nullif(btrim(new.course_name), ''), 'Your course');
  note := nullif(btrim(coalesce(new.review_note, '')), '');

  insert into public.notifications (
    external_id,
    recipient_user_id,
    title,
    message,
    created_by,
    created_by_name
  )
  values (
    'course-review::' || new.id::text || '::' || gen_random_uuid()::text,
    new.owner_id,
    case
      when new.review_status = 'approved' then 'Course approved'
      else 'Course needs changes'
    end,
    case
      when new.review_status = 'approved' then
        course_label || ' was approved. You can publish it to students now.'
        || coalesce(' Reviewer note: ' || note, '')
      else
        course_label || ' was not approved yet.'
        || coalesce(' Reviewer note: ' || note, '')
        || ' Update it and submit it for review again.'
    end,
    new.reviewed_by,
    coalesce(reviewer_name, 'MedBank')
  );

  return new;
end;
$$;

revoke all on function private.notify_course_owner_on_review() from public;

drop trigger if exists platform_courses_notify_owner_on_review
  on public.platform_courses;
create trigger platform_courses_notify_owner_on_review
  after update of review_status on public.platform_courses
  for each row
  execute function private.notify_course_owner_on_review();
