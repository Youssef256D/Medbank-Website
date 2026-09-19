-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

create or replace function private.can_select_platform_course(
  target_course_id uuid,
  target_enrollment_mode text,
  target_is_active boolean,
  target_is_published boolean
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select private.is_active_platform_student()
    and target_is_active is true
    and target_is_published is true;
$$;
