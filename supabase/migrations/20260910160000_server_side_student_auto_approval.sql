-- Server-side student auto-approval.
--
-- Until now the auto-approval sweep lived only in `ensureAdminDashboardPolling()`
-- in main.js, so it ran solely inside an admin's browser while the admin
-- dashboard was open. With no admin watching, eligible students were never
-- approved -- verified on this project: two students with a valid phone, year,
-- semester and five enrolments each sat unapproved with `updated_at` still equal
-- to `created_at`, meaning nothing had ever processed them.
--
-- This moves the decision into the database. The client sweep stays as-is and is
-- now redundant rather than load-bearing.
--
-- Design rules, all deliberate:
--   * GRANT ONLY. Nothing here ever sets `approved` to false.
--   * The eligibility rule is a faithful port of the app's own
--     `hasCompleteStudentProfile` + `hasSelectedStudentCourses`. If the two ever
--     disagree the admin Users page will contradict itself, showing
--     "Not auto-approved - needs ..." on an already-approved account.
--   * The existing `student_auto_approval` feature flag still governs it, so the
--     admin switch keeps working and remains the off switch.
--   * An admin suspension is never undone. See `auto_approval_blocked_at` below.

begin;

-- `profiles.approved` is NOT NULL DEFAULT false, so a never-decided account and
-- a deliberately suspended one are indistinguishable. Without this column the
-- sweep would re-approve every suspended student on its next run and suspension
-- would silently stop working. Stamped by the trigger, so every client (website,
-- mobile app, admin agent, raw SQL) gets the same protection for free.
alter table public.profiles
  add column if not exists auto_approval_blocked_at timestamptz;

comment on column public.profiles.auto_approval_blocked_at is
  'Set when approved goes true -> false (an explicit suspension). While non-null, automatic approval skips this account. Cleared whenever approved is set true.';

-- Faithful port of validateAndNormalizePhoneNumber() in main.js, including
-- normalizePhoneInput and the PHONE_COUNTRY_RULES table. Kept in step with that
-- function; a mismatch shows up as the admin badge disagreeing with the row.
create or replace function private.student_phone_is_valid(raw_phone text)
returns boolean
language plpgsql
immutable
as $$
declare
  compact text;
  normalized text;
  intl text;
  digits text;
  code text;
  national text;
begin
  if btrim(coalesce(raw_phone, '')) = '' then
    return false;
  end if;

  compact := regexp_replace(btrim(raw_phone), '[^0-9+]', '', 'g');
  if compact = '' then
    return false;
  end if;

  if left(compact, 1) = '+' then
    normalized := '+' || regexp_replace(substr(compact, 2), '[^0-9]', '', 'g');
  else
    normalized := regexp_replace(compact, '[^0-9]', '', 'g');
  end if;
  if normalized = '' or normalized = '+' then
    return false;
  end if;

  -- Egypt local form, handled before the international branch exactly as the app does.
  if left(normalized, 2) = '01' then
    return normalized ~ '^01(0|1|2|5)[0-9]{8}$';
  end if;

  intl := normalized;
  if left(intl, 2) = '00' then
    intl := '+' || substr(intl, 3);
  end if;
  if left(intl, 1) <> '+' then
    return false;
  end if;

  digits := substr(intl, 2);
  if digits !~ '^[0-9]{8,15}$' then
    return false;
  end if;

  -- Longest dialling code first, mirroring PHONE_COUNTRY_CODES_DESC.
  select t.c into code
  from unnest(array['966','971','20','44','91','33','49','1']) with ordinality as t(c, ord)
  where left(digits, length(t.c)) = t.c
  order by t.ord
  limit 1;

  -- No known rule means "International" in the app, which it accepts.
  if code is null then
    return true;
  end if;

  national := substr(digits, length(code) + 1);
  return case code
    when '20'  then national ~ '^(10|11|12|15)[0-9]{8}$'
    when '1'   then national ~ '^[2-9][0-9]{9}$'
    when '44'  then national ~ '^[0-9]{9,10}$'
    when '966' then national ~ '^[0-9]{9}$'
    when '971' then national ~ '^[0-9]{8,9}$'
    when '91'  then national ~ '^[6-9][0-9]{9}$'
    when '33'  then national ~ '^[0-9]{9}$'
    when '49'  then national ~ '^[0-9]{7,13}$'
    else true
  end;
end;
$$;

-- Port of hasCompleteStudentProfile() AND hasSelectedStudentCourses().
-- SECURITY DEFINER because it is called from a trigger that a student's own
-- profile write fires: under RLS that student cannot read public.courses or
-- another row's enrolments, and a false negative would silently withhold approval.
create or replace function private.student_profile_is_complete(
  p_role text,
  p_phone text,
  p_year smallint,
  p_semester smallint,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, private
as $$
begin
  if coalesce(p_role, '') <> 'student' then
    return false;
  end if;
  if not private.student_phone_is_valid(p_phone) then
    return false;
  end if;
  if p_year is null or p_year < 1 or p_year > 5 then
    return false;
  end if;
  if p_semester is null or p_semester not in (1, 2) then
    return false;
  end if;

  -- hasSelectedStudentCourses: a valid term whose curriculum offers courses
  -- satisfies this on its own; otherwise fall back to explicit enrolments.
  if exists (
    select 1 from public.courses c
    where c.academic_year = p_year
      and c.academic_semester = p_semester
      and c.is_active
  ) then
    return true;
  end if;

  return exists (
    select 1 from public.user_course_enrollments e
    where e.user_id = p_user_id
  );
end;
$$;

create or replace function private.profiles_auto_approval()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  -- Suspension bookkeeping first. An admin moving approved true -> false is a
  -- decision the automation must never reverse, and re-approving on the next
  -- unrelated profile edit is exactly the bug this guards against.
  if tg_op = 'UPDATE' and old.approved is true and new.approved is false then
    new.auto_approval_blocked_at := now();
  elsif new.approved is true then
    new.auto_approval_blocked_at := null;
  end if;

  -- Grant only, and never at the cost of the write itself: a fault in the
  -- eligibility check must not make a student unable to save their profile.
  begin
    if new.approved is not true
       and new.auto_approval_blocked_at is null
       and private.is_app_feature_enabled('student_auto_approval')
       and private.student_profile_is_complete(
             new.role::text, new.phone, new.academic_year, new.academic_semester, new.id)
    then
      new.approved := true;
    end if;
  exception when others then
    null;
  end;

  return new;
end;
$$;

drop trigger if exists trg_profiles_auto_approval on public.profiles;
create trigger trg_profiles_auto_approval
before insert or update on public.profiles
for each row
execute function private.profiles_auto_approval();

-- Backstop for eligibility that becomes true without a profiles write of its own
-- (an enrolment row landing later, the feature flag being switched on, or a
-- course being added to a curriculum).
create or replace function private.run_student_auto_approval_sweep()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  approved_count integer := 0;
begin
  if not private.is_app_feature_enabled('student_auto_approval') then
    return 0;
  end if;

  update public.profiles t
  set approved = true
  where t.id in (
    select p.id
    from public.profiles p
    where p.role = 'student'
      and p.approved is not true
      and p.auto_approval_blocked_at is null
      and private.student_profile_is_complete(
            p.role::text, p.phone, p.academic_year, p.academic_semester, p.id)
  );

  get diagnostics approved_count = row_count;
  return approved_count;
end;
$$;

revoke all on function private.student_phone_is_valid(text) from anon, authenticated;
revoke all on function private.student_profile_is_complete(text, text, smallint, smallint, uuid) from anon, authenticated;
revoke all on function private.run_student_auto_approval_sweep() from anon, authenticated;

commit;
