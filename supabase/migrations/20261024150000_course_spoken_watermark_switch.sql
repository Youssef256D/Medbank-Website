-- Per-course switch for the spoken MedBank ID (the audio watermark).
--
-- Every few minutes a lesson pauses and says the student's MedBank ID, so a
-- voice recording of it names whose copy it was. Some courses do not need it
-- (free previews, a lecturer who finds it intrusive), so an admin can turn it
-- off per course. On by default: every existing course keeps it.
--
-- The on-screen watermark is not affected. Only an admin may change the
-- switch: creators can update their own course rows, so without the trigger a
-- creator could turn off the protection on their own course from the API.

alter table public.platform_courses
  add column if not exists spoken_watermark_enabled boolean not null default true;

comment on column public.platform_courses.spoken_watermark_enabled is
  'Whether lessons in this course speak the student''s MedBank ID every few minutes. Admin-only.';

create or replace function private.guard_spoken_watermark_switch()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if private.is_admin_user() or not private.is_creator_user() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.spoken_watermark_enabled := true;
    return new;
  end if;

  if new.spoken_watermark_enabled is distinct from old.spoken_watermark_enabled then
    raise exception 'Only an admin can change the spoken MedBank ID.'
      using errcode = '42501';
  end if;

  return new;
end;
$function$;

revoke all on function private.guard_spoken_watermark_switch() from public, anon, authenticated;

create trigger trg_platform_courses_spoken_watermark_switch
  before insert or update of spoken_watermark_enabled on public.platform_courses
  for each row execute function private.guard_spoken_watermark_switch();
