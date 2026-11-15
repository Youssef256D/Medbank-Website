-- Programs (`public.university_colleges`): scope MCQ Bank subjects, eligibility,
-- academic year/semester bounds, signup catalog, enrollments, auto-approval,
-- subject copying, and leaderboards to a (university, college) program while
-- keeping all existing O6U Medicine students and legacy app/website builds
-- working unchanged.

-- ============================================================================
-- 1. Programs table (`public.university_colleges`)
-- ============================================================================

create table if not exists public.university_colleges (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id) on delete restrict,
  college_key text not null,
  name text not null,
  name_ar text,
  years_count smallint not null default 5,
  semesters_per_year smallint not null default 2,
  mcq_bank_available boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint university_colleges_college_key_ck
    check (college_key ~ '^[a-z][a-z0-9_]{1,39}$'),
  constraint university_colleges_name_not_blank_ck
    check (length(trim(name)) >= 2),
  constraint university_colleges_years_count_ck
    check (years_count between 1 and 7),
  constraint university_colleges_semesters_per_year_ck
    check (semesters_per_year between 1 and 3),
  constraint university_colleges_university_college_key_uniq
    unique (university_id, college_key)
);

create index if not exists university_colleges_university_id_idx
  on public.university_colleges (university_id);

drop trigger if exists trg_university_colleges_updated_at on public.university_colleges;
create trigger trg_university_colleges_updated_at
  before update on public.university_colleges
  for each row execute function public.set_updated_at();

alter table public.university_colleges enable row level security;

drop policy if exists university_colleges_select on public.university_colleges;
create policy university_colleges_select on public.university_colleges
  for select to anon, authenticated
  using (is_active or (select private.is_admin_user()));

drop policy if exists university_colleges_admin_insert on public.university_colleges;
create policy university_colleges_admin_insert on public.university_colleges
  for insert to authenticated
  with check (
    (select private.is_admin_user())
    and (select private.admin_write_allowed('mcq'))
  );

drop policy if exists university_colleges_admin_update on public.university_colleges;
create policy university_colleges_admin_update on public.university_colleges
  for update to authenticated
  using (
    (select private.is_admin_user())
    and (select private.admin_write_allowed('mcq'))
  )
  with check (
    (select private.is_admin_user())
    and (select private.admin_write_allowed('mcq'))
  );

drop policy if exists university_colleges_admin_delete on public.university_colleges;
create policy university_colleges_admin_delete on public.university_colleges
  for delete to authenticated
  using (
    (select private.is_admin_user())
    and (select private.admin_write_allowed('mcq'))
  );

revoke all on public.university_colleges from public, anon, authenticated;
grant select on public.university_colleges to anon, authenticated;
grant insert, update, delete on public.university_colleges to authenticated;

create or replace function private.guard_university_college_delete()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if exists (
    select 1
    from public.profiles p
    where p.university_id = old.university_id
      and lower(trim(coalesce(p.college, ''))) = old.college_key
  ) then
    raise exception using errcode = '23503', message = 'PROGRAM_HAS_STUDENTS';
  end if;
  return old;
end;
$$;

revoke all on function private.guard_university_college_delete()
  from public, anon, authenticated;

drop trigger if exists trg_university_colleges_guard_delete on public.university_colleges;
create trigger trg_university_colleges_guard_delete
  before delete on public.university_colleges
  for each row execute function private.guard_university_college_delete();

-- ============================================================================
-- 2. Seed default 7 colleges per existing university + trigger for new ones
-- ============================================================================

insert into public.university_colleges (
  university_id,
  college_key,
  name,
  name_ar,
  years_count,
  semesters_per_year,
  mcq_bank_available,
  is_active,
  sort_order
)
select
  u.id,
  v.college_key,
  v.name,
  v.name_ar,
  5,
  2,
  (u.mcq_bank_available and v.college_key = 'medicine'),
  true,
  v.sort_order
from public.universities u
cross join (
  values
    ('medicine',                'Medicine',                'الطب البشري',               10),
    ('dentistry',               'Dentistry',               'طب الأسنان',                20),
    ('pharmacy',                'Pharmacy',                'الصيدلة',                   30),
    ('nursing',                 'Nursing',                 'التمريض',                   40),
    ('physical_therapy',        'Physical Therapy',        'العلاج الطبيعي',            50),
    ('applied_health_sciences', 'Applied Health Sciences', 'العلوم الصحية التطبيقية',    60),
    ('other',                   'Other',                   'أخرى',                     70)
) as v(college_key, name, name_ar, sort_order)
on conflict (university_id, college_key) do nothing;

create or replace function private.seed_default_colleges_for_university()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  insert into public.university_colleges (
    university_id,
    college_key,
    name,
    name_ar,
    years_count,
    semesters_per_year,
    mcq_bank_available,
    is_active,
    sort_order
  )
  values
    (new.id, 'medicine',                'Medicine',                'الطب البشري',               5, 2, false, true, 10),
    (new.id, 'dentistry',               'Dentistry',               'طب الأسنان',                5, 2, false, true, 20),
    (new.id, 'pharmacy',                'Pharmacy',                'الصيدلة',                   5, 2, false, true, 30),
    (new.id, 'nursing',                 'Nursing',                 'التمريض',                   5, 2, false, true, 40),
    (new.id, 'physical_therapy',        'Physical Therapy',        'العلاج الطبيعي',            5, 2, false, true, 50),
    (new.id, 'applied_health_sciences', 'Applied Health Sciences', 'العلوم الصحية التطبيقية',    5, 2, false, true, 60),
    (new.id, 'other',                   'Other',                   'أخرى',                     5, 2, false, true, 70)
  on conflict (university_id, college_key) do nothing;

  return null;
end;
$$;

revoke all on function private.seed_default_colleges_for_university()
  from public, anon, authenticated;

drop trigger if exists trg_universities_seed_colleges on public.universities;
create trigger trg_universities_seed_colleges
  after insert on public.universities
  for each row execute function private.seed_default_colleges_for_university();

-- ============================================================================
-- 3. Program lookup helper
-- ============================================================================

create or replace function private.profile_program_id(
  p_university_id uuid,
  p_college text
)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select uc.id
  from public.university_colleges uc
  where uc.university_id = p_university_id
    and uc.college_key = lower(trim(coalesce(p_college, '')))
  limit 1;
$$;

revoke all on function private.profile_program_id(uuid, text)
  from public, anon, authenticated;

-- ============================================================================
-- 4. Courses: add `program_id`, backfill to O6U medicine, widen term checks
-- ============================================================================

alter table public.courses
  add column if not exists program_id uuid
    references public.university_colleges(id) on delete restrict;

do $$
declare
  v_o6u_medicine_id uuid;
begin
  select uc.id
    into v_o6u_medicine_id
  from public.university_colleges uc
  join public.universities u on u.id = uc.university_id
  where lower(trim(u.name)) = 'october 6 university'
    and uc.college_key = 'medicine'
  limit 1;

  if v_o6u_medicine_id is null then
    raise exception 'O6U medicine program row not found for courses backfill';
  end if;

  update public.courses
  set program_id = v_o6u_medicine_id
  where program_id is null;
end $$;

alter table public.courses
  alter column program_id set not null;

create index if not exists courses_program_year_sem_idx
  on public.courses (program_id, academic_year, academic_semester);

alter table public.courses
  drop constraint if exists courses_name_year_sem_uniq;
alter table public.courses
  drop constraint if exists courses_program_name_year_sem_uniq;
alter table public.courses
  add constraint courses_program_name_year_sem_uniq
    unique (program_id, course_name, academic_year, academic_semester);

alter table public.courses
  drop constraint if exists courses_academic_year_check;
alter table public.courses
  drop constraint if exists courses_academic_semester_check;
alter table public.courses
  drop constraint if exists courses_academic_year_range_ck;
alter table public.courses
  add constraint courses_academic_year_range_ck
    check (academic_year between 1 and 7);
alter table public.courses
  drop constraint if exists courses_academic_semester_range_ck;
alter table public.courses
  add constraint courses_academic_semester_range_ck
    check (academic_semester between 1 and 3);

-- Compat: legacy admin clients insert courses without program_id; fill O6U medicine
-- before NOT NULL and before the program term-bounds trigger.
create or replace function private.fill_course_default_program_id()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_o6u_medicine_id uuid;
begin
  if new.program_id is null then
    select uc.id
      into v_o6u_medicine_id
    from public.university_colleges uc
    join public.universities u on u.id = uc.university_id
    where lower(trim(u.name)) = 'october 6 university'
      and uc.college_key = 'medicine'
    limit 1;

    new.program_id := v_o6u_medicine_id;
  end if;
  return new;
end;
$$;

revoke all on function private.fill_course_default_program_id()
  from public, anon, authenticated;

drop trigger if exists trg_courses_10_default_program_id on public.courses;
create trigger trg_courses_10_default_program_id
  before insert on public.courses
  for each row execute function private.fill_course_default_program_id();

create or replace function private.enforce_course_term_within_program()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_years_count smallint;
  v_semesters_per_year smallint;
begin
  if new.program_id is not null then
    select uc.years_count, uc.semesters_per_year
      into v_years_count, v_semesters_per_year
    from public.university_colleges uc
    where uc.id = new.program_id;

    if found and (
      new.academic_year > v_years_count
      or new.academic_semester > v_semesters_per_year
    ) then
      raise exception using errcode = '23514', message = 'TERM_OUTSIDE_PROGRAM';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_course_term_within_program()
  from public, anon, authenticated;

drop trigger if exists trg_courses_20_term_within_program on public.courses;
create trigger trg_courses_20_term_within_program
  before insert or update on public.courses
  for each row execute function private.enforce_course_term_within_program();

-- ============================================================================
-- 5. Profiles: generic year/semester/college constraints
-- ============================================================================

alter table public.profiles
  drop constraint if exists profiles_year_ck;
alter table public.profiles
  add constraint profiles_year_ck
    check (academic_year is null or academic_year between 1 and 7);

alter table public.profiles
  drop constraint if exists profiles_semester_ck;
alter table public.profiles
  add constraint profiles_semester_ck
    check (academic_semester is null or academic_semester between 1 and 3);

alter table public.profiles
  drop constraint if exists profiles_student_approved_requires_completi;
alter table public.profiles
  add constraint profiles_student_approved_requires_completi
    check (
      role <> 'student'::public.app_user_role
      or approved is not true
      or (
        length(regexp_replace(coalesce(phone, ''), '\D', '', 'g')) >= 8
        and academic_year is not null
        and academic_year >= 1
        and academic_semester is not null
        and academic_semester >= 1
      )
    );

alter table public.profiles
  drop constraint if exists profiles_college_ck;
alter table public.profiles
  drop constraint if exists profiles_college_key_ck;
alter table public.profiles
  add constraint profiles_college_key_ck
    check (college is null or college ~ '^[a-z][a-z0-9_]{1,39}$');

-- ============================================================================
-- 6. Eligibility, profile enforcement, access checks, and sync triggers
-- ============================================================================

-- Based on: ../MedBank Website/supabase/migrations/20260928083023_universities_and_college_mcq_eligibility.sql
create or replace function private.is_mcq_eligible(
  target_role public.app_user_role,
  target_university_id uuid,
  target_college text
)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select case
    when target_role <> 'student'::public.app_user_role then true
    else exists (
      select 1
      from public.universities u
      join public.university_colleges uc
        on uc.university_id = u.id
      where u.id = target_university_id
        and u.mcq_bank_available is true
        and uc.college_key = lower(trim(coalesce(target_college, '')))
        and uc.is_active is true
        and uc.mcq_bank_available is true
    )
  end;
$$;

-- Based on: ../MedBank Website/supabase/migrations/20260928125817_student_auto_mcq_access.sql
create or replace function private.enforce_profile_mcq_eligibility()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  caller uuid := (select auth.uid());
  caller_is_admin boolean := coalesce((select private.is_admin_user()), false);
  eligible boolean;
  was_eligible boolean := false;
  prog_years smallint;
  prog_semesters smallint;
begin
  -- A student editing their own row can never touch their MCQ state.
  if tg_op = 'UPDATE' and caller is not null and caller = new.id
     and not caller_is_admin then
    new.mcq_access_enabled := old.mcq_access_enabled;
    new.mcq_access_held_at := old.mcq_access_held_at;
  end if;

  -- A student may only pick a university that is on the public list.
  if caller is not null and not caller_is_admin
     and new.university_id is not null
     and (tg_op = 'INSERT' or new.university_id is distinct from old.university_id)
     and not exists (
       select 1 from public.universities u
       where u.id = new.university_id and u.is_active
     ) then
    raise exception using errcode = '23514', message = 'UNIVERSITY_NOT_AVAILABLE';
  end if;

  -- Non-admin callers setting/changing university_id or college (both non-null)
  -- must pick an active program for that university.
  if caller is not null and not caller_is_admin
     and new.university_id is not null
     and new.college is not null
     and (
       tg_op = 'INSERT'
       or new.university_id is distinct from old.university_id
       or new.college is distinct from old.college
     )
     and not exists (
       select 1 from public.university_colleges uc
       where uc.university_id = new.university_id
         and uc.college_key = new.college
         and uc.is_active is true
     ) then
    raise exception using errcode = '23514', message = 'COLLEGE_NOT_AVAILABLE';
  end if;

  -- Non-admin callers with a known program cannot pick a year or semester
  -- outside that program's bounds.
  if caller is not null and not caller_is_admin
     and new.university_id is not null
     and new.college is not null
     and (new.academic_year is not null or new.academic_semester is not null) then
    select uc.years_count, uc.semesters_per_year
      into prog_years, prog_semesters
    from public.university_colleges uc
    where uc.university_id = new.university_id
      and uc.college_key = new.college;

    if found and (
      (new.academic_year is not null and new.academic_year > prog_years)
      or (new.academic_semester is not null and new.academic_semester > prog_semesters)
    ) then
      raise exception using errcode = '23514', message = 'TERM_OUTSIDE_PROGRAM';
    end if;
  end if;

  eligible := private.is_mcq_eligible(new.role, new.university_id, new.college);
  if tg_op = 'UPDATE' then
    was_eligible := private.is_mcq_eligible(old.role, old.university_id, old.college);
  end if;

  if not eligible then
    new.mcq_access_enabled := false;
  elsif new.role = 'student'::public.app_user_role
        and (tg_op = 'INSERT' or not was_eligible) then
    -- Becoming eligible (a new account, or one that just filled in its
    -- university/college): the switch decides. With it on, an insert keeps
    -- the value it was created with (the column default is on).
    if not private.is_app_feature_enabled('student_auto_mcq_access') then
      new.mcq_access_enabled := false;
      new.mcq_access_held_at := now();
    elsif tg_op = 'UPDATE' then
      new.mcq_access_enabled := true;
    end if;
  end if;

  -- A hold only means something while access is off and could be granted.
  if new.mcq_access_enabled or not eligible
     or new.role <> 'student'::public.app_user_role then
    new.mcq_access_held_at := null;
  end if;

  return new;
end;
$$;

-- Based on: ../MedBank Website/supabase/migrations/20260928083023_universities_and_college_mcq_eligibility.sql
create or replace function private.can_current_user_access_mcq()
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and (
        (p.role = 'admin' and p.approved is true)
        or (
          p.role = 'student'
          and p.approved is true
          and p.mcq_access_enabled is true
          and private.is_mcq_eligible(p.role, p.university_id, p.college)
        )
      )
  );
$$;

-- Based on: ../MedBank Website/supabase/migrations/20261013190634_user_course_locks.sql
create or replace function private.can_current_user_access_question(
  target_course_id uuid,
  target_topic_id uuid
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.user_course_enrollments e
    join public.profiles p on p.id = e.user_id
    join public.courses enrolled_course on enrolled_course.id = e.course_id
    join public.courses question_course on question_course.id = target_course_id
    join public.course_topics question_topic on question_topic.id = target_topic_id
    where e.user_id = (select auth.uid())
      and enrolled_course.is_active is true
      and question_course.is_active is true
      and question_topic.is_active is true
      and question_topic.course_id = question_course.id
      and enrolled_course.program_id = question_course.program_id
      and question_course.program_id = private.profile_program_id(p.university_id, p.college)
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
      and not exists (
        select 1
        from (values (e.course_id), (question_course.id)) as checked(course_id)
        where coalesce(
          (select o.locked
             from public.user_course_locks o
            where o.user_id = e.user_id and o.course_id = checked.course_id),
          exists (select 1 from public.course_locks g where g.course_id = checked.course_id)
        )
      )
  );
$function$;

-- Based on: ../MedBank Website/supabase/migrations/20260928083023_universities_and_college_mcq_eligibility.sql
create or replace function private.sync_university_mcq_availability()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  auto_mcq boolean := coalesce(private.is_app_feature_enabled('student_auto_mcq_access'), true);
begin
  if new.mcq_bank_available is distinct from old.mcq_bank_available then
    if new.mcq_bank_available is true then
      update public.profiles p
      set
        mcq_access_enabled = auto_mcq,
        mcq_access_held_at = case when auto_mcq then null else now() end
      where p.university_id = new.id
        and p.role = 'student'::public.app_user_role
        and private.is_mcq_eligible(p.role, p.university_id, p.college);
    else
      update public.profiles p
      set
        mcq_access_enabled = false,
        mcq_access_held_at = null
      where p.university_id = new.id
        and p.role = 'student'::public.app_user_role
        and exists (
          select 1
          from public.university_colleges uc
          where uc.university_id = new.id
            and uc.college_key = lower(trim(coalesce(p.college, '')))
            and uc.is_active is true
            and uc.mcq_bank_available is true
        );
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.sync_program_mcq_availability()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  univ_has_mcq boolean;
  was_eligible boolean;
  now_eligible boolean;
  auto_mcq boolean;
begin
  if (new.mcq_bank_available is not distinct from old.mcq_bank_available)
     and (new.is_active is not distinct from old.is_active) then
    return new;
  end if;

  select u.mcq_bank_available
    into univ_has_mcq
  from public.universities u
  where u.id = new.university_id;

  univ_has_mcq := coalesce(univ_has_mcq, false);
  was_eligible := univ_has_mcq and old.is_active and old.mcq_bank_available;
  now_eligible := univ_has_mcq and new.is_active and new.mcq_bank_available;

  if was_eligible is distinct from now_eligible then
    if now_eligible then
      auto_mcq := coalesce(private.is_app_feature_enabled('student_auto_mcq_access'), true);
      update public.profiles p
      set
        mcq_access_enabled = auto_mcq,
        mcq_access_held_at = case when auto_mcq then null else now() end
      where p.university_id = new.university_id
        and lower(trim(coalesce(p.college, ''))) = new.college_key
        and p.role = 'student'::public.app_user_role;
    else
      update public.profiles p
      set
        mcq_access_enabled = false,
        mcq_access_held_at = null
      where p.university_id = new.university_id
        and lower(trim(coalesce(p.college, ''))) = new.college_key
        and p.role = 'student'::public.app_user_role;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_program_mcq_availability()
  from public, anon, authenticated;

drop trigger if exists trg_university_colleges_sync_mcq on public.university_colleges;
create trigger trg_university_colleges_sync_mcq
  after update of mcq_bank_available, is_active on public.university_colleges
  for each row execute function private.sync_program_mcq_availability();

-- ============================================================================
-- 7. Enrollment per program
-- ============================================================================

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
create or replace function private.sync_profile_term_course_enrollments(
  target_profile_id uuid,
  assigned_by_profile_id uuid default null::uuid
)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  profile_row record;
  target_program_id uuid;
begin
  if target_profile_id is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.courses') is null
     or to_regclass('public.user_course_enrollments') is null then
    return;
  end if;

  select
    p.id,
    p.role,
    p.academic_year,
    p.academic_semester,
    p.university_id,
    p.college
  into profile_row
  from public.profiles p
  where p.id = target_profile_id;

  if not found then
    return;
  end if;

  target_program_id := private.profile_program_id(profile_row.university_id, profile_row.college);

  if profile_row.role <> 'student'
     or profile_row.academic_year is null
     or profile_row.academic_semester is null
     or target_program_id is null then
    delete from public.user_course_enrollments e
    where e.user_id = profile_row.id;
    return;
  end if;

  delete from public.user_course_enrollments e
  using public.courses c
  where e.user_id = profile_row.id
    and c.id = e.course_id
    and (
      c.is_active is not true
      or c.program_id is distinct from target_program_id
      or c.academic_year is distinct from profile_row.academic_year
      or c.academic_semester is distinct from profile_row.academic_semester
    );

  insert into public.user_course_enrollments (
    user_id,
    course_id,
    assigned_by
  )
  select
    profile_row.id,
    c.id,
    assigned_by_profile_id
  from public.courses c
  where c.is_active is true
    and c.program_id = target_program_id
    and c.academic_year = profile_row.academic_year
    and c.academic_semester = profile_row.academic_semester
  on conflict (user_id, course_id) do update
  set assigned_by = coalesce(public.user_course_enrollments.assigned_by, excluded.assigned_by);
end;
$function$;

revoke all on function private.sync_profile_term_course_enrollments(uuid, uuid)
  from public, anon, authenticated;

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
create or replace function private.sync_profiles_for_course_term(
  target_program_id uuid,
  target_year smallint,
  target_semester smallint
)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  profile_id uuid;
begin
  if target_program_id is null
     or target_year is null
     or target_semester is null
     or to_regclass('public.profiles') is null then
    return;
  end if;

  for profile_id in
    select p.id
    from public.profiles p
    where p.role = 'student'
      and p.academic_year = target_year
      and p.academic_semester = target_semester
      and private.profile_program_id(p.university_id, p.college) = target_program_id
  loop
    perform private.sync_profile_term_course_enrollments(profile_id, null);
  end loop;
end;
$function$;

revoke all on function private.sync_profiles_for_course_term(uuid, smallint, smallint)
  from public, anon, authenticated;

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
create or replace function private.handle_course_term_enrollment_sync()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
begin
  if tg_op = 'INSERT' then
    perform private.sync_profiles_for_course_term(
      new.program_id, new.academic_year, new.academic_semester
    );
    return new;
  end if;

  if tg_op = 'UPDATE' then
    perform private.sync_profiles_for_course_term(
      new.program_id, new.academic_year, new.academic_semester
    );
    if old.program_id is distinct from new.program_id
       or old.academic_year is distinct from new.academic_year
       or old.academic_semester is distinct from new.academic_semester then
      perform private.sync_profiles_for_course_term(
        old.program_id, old.academic_year, old.academic_semester
      );
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    perform private.sync_profiles_for_course_term(
      old.program_id, old.academic_year, old.academic_semester
    );
    return old;
  end if;

  return null;
end;
$function$;

revoke all on function private.handle_course_term_enrollment_sync()
  from public, anon, authenticated;

drop function if exists private.sync_profiles_for_course_term(smallint, smallint);

drop trigger if exists trg_courses_sync_term_enrollments on public.courses;
create trigger trg_courses_sync_term_enrollments
  after insert or update of program_id, academic_year, academic_semester, is_active
  on public.courses
  for each row execute function private.handle_course_term_enrollment_sync();

drop trigger if exists trg_profiles_sync_term_enrollments on public.profiles;
create trigger trg_profiles_sync_term_enrollments
  after insert or update of role, academic_year, academic_semester, university_id, college
  on public.profiles
  for each row execute function private.handle_profile_term_enrollment_sync();

-- Clean up any pre-migration enrollments where a non-O6U-medicine student was
-- enrolled in O6U medicine courses before courses were scoped to programs.
-- Existing O6U medicine students match every backfilled course and keep theirs.
delete from public.user_course_enrollments e
using public.profiles p, public.courses c
where p.id = e.user_id
  and c.id = e.course_id
  and c.program_id is distinct from private.profile_program_id(p.university_id, p.college);

-- ============================================================================
-- 8. Profile completeness and student auto-approval per program
-- ============================================================================

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
create or replace function private.student_profile_is_complete(
  p_role text,
  p_phone text,
  p_year smallint,
  p_semester smallint,
  p_user_id uuid,
  p_university_id uuid,
  p_college text
)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'private'
as $function$
declare
  v_program_id uuid;
  v_years_count smallint := 5;
  v_semesters_per_year smallint := 2;
begin
  if coalesce(p_role, '') <> 'student' then
    return false;
  end if;
  if not private.student_phone_is_valid(p_phone) then
    return false;
  end if;

  v_program_id := private.profile_program_id(p_university_id, p_college);
  if v_program_id is not null then
    select uc.years_count, uc.semesters_per_year
      into v_years_count, v_semesters_per_year
    from public.university_colleges uc
    where uc.id = v_program_id;
  end if;

  if p_year is null or p_year < 1 or p_year > v_years_count then
    return false;
  end if;
  if p_semester is null or p_semester < 1 or p_semester > v_semesters_per_year then
    return false;
  end if;

  if v_program_id is not null and exists (
    select 1 from public.courses c
    where c.program_id = v_program_id
      and c.academic_year = p_year
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
$function$;

revoke all on function private.student_profile_is_complete(text, text, smallint, smallint, uuid, uuid, text)
  from public, anon, authenticated;

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
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
set search_path to 'public', 'private'
as $function$
declare
  v_university_id uuid;
  v_college text;
begin
  if p_user_id is not null then
    select p.university_id, p.college
      into v_university_id, v_college
    from public.profiles p
    where p.id = p_user_id;
  end if;

  return private.student_profile_is_complete(
    p_role, p_phone, p_year, p_semester, p_user_id, v_university_id, v_college
  );
end;
$function$;

revoke all on function private.student_profile_is_complete(text, text, smallint, smallint, uuid)
  from public, anon, authenticated;

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
create or replace function private.profiles_auto_approval()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
begin
  if tg_op = 'UPDATE' and old.approved is true and new.approved is false then
    new.auto_approval_blocked_at := now();
  elsif new.approved is true then
    new.auto_approval_blocked_at := null;
  end if;

  begin
    if new.approved is not true
       and new.auto_approval_blocked_at is null
       and private.is_app_feature_enabled('student_auto_approval')
       and private.student_profile_is_complete(
             new.role::text, new.phone, new.academic_year, new.academic_semester, new.id,
             new.university_id, new.college)
    then
      new.approved := true;
    end if;
  exception when others then
    null;
  end;

  return new;
end;
$function$;

revoke all on function private.profiles_auto_approval()
  from public, anon, authenticated;

-- Based on: live production definition (supabase/tests/mcq_programs/LIVE_DEFINITIONS.sql)
create or replace function private.run_student_auto_approval_sweep()
returns integer
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
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
            p.role::text, p.phone, p.academic_year, p.academic_semester, p.id,
            p.university_id, p.college)
  );

  get diagnostics approved_count = row_count;
  return approved_count;
end;
$function$;

revoke all on function private.run_student_auto_approval_sweep()
  from public, anon, authenticated;

-- ============================================================================
-- 9. Signup programs & course catalog, MCQ leaderboard, weekly winners, auth bootstrap
-- ============================================================================

create or replace function public.get_signup_programs()
returns table (
  program_id uuid,
  university_id uuid,
  college_key text,
  name text,
  name_ar text,
  years_count integer,
  semesters_per_year integer,
  mcq_bank_available boolean,
  sort_order integer
)
language sql
stable
security definer
set search_path to ''
as $$
  select
    uc.id as program_id,
    uc.university_id,
    uc.college_key,
    uc.name,
    uc.name_ar,
    uc.years_count::integer,
    uc.semesters_per_year::integer,
    (u.mcq_bank_available and uc.mcq_bank_available) as mcq_bank_available,
    uc.sort_order::integer
  from public.university_colleges uc
  join public.universities u on u.id = uc.university_id
  where uc.is_active is true
    and u.is_active is true
  order by u.sort_order, uc.sort_order, uc.name;
$$;

revoke all on function public.get_signup_programs() from public;
grant execute on function public.get_signup_programs() to anon, authenticated;

-- Based on: ../MedBank Website/supabase/migrations/20261019150000_signup_course_catalog.sql
drop function if exists public.get_signup_course_catalog();
create or replace function public.get_signup_course_catalog(
  p_program_id uuid default null
)
returns table (
  course_name text,
  academic_year integer,
  academic_semester integer
)
language sql
stable
security definer
set search_path to ''
as $$
  select
    trim(c.course_name)::text,
    c.academic_year::integer,
    c.academic_semester::integer
  from public.courses c
  join public.university_colleges uc on uc.id = c.program_id
  join public.universities u on u.id = uc.university_id
  where c.is_active is true
    and (
      (
        p_program_id is null
        and lower(trim(u.name)) = 'october 6 university'
        and uc.college_key = 'medicine'
        and coalesce(trim(c.course_name), '') <> ''
        and c.academic_year between 1 and 5
        and c.academic_semester between 1 and 2
      )
      or (
        p_program_id is not null
        and c.program_id = p_program_id
        and c.academic_year between 1 and uc.years_count
        and c.academic_semester between 1 and uc.semesters_per_year
      )
    )
  order by c.academic_year, c.academic_semester, c.course_name;
$$;

revoke all on function public.get_signup_course_catalog(uuid) from public;
grant execute on function public.get_signup_course_catalog(uuid) to anon, authenticated;

-- Based on: ./supabase/migrations/20261031150000_mcq_leaderboard.sql
create or replace function public.get_mcq_leaderboard(
  p_period text default 'week',
  p_limit integer default 50
)
returns table (
  rank integer,
  display_name text,
  points integer,
  is_me boolean,
  is_hidden boolean
)
language plpgsql
stable
security definer
set search_path to ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_university uuid;
  v_college text;
  v_year smallint;
  v_since timestamptz;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if p_period is null or p_period not in ('week', 'all') then
    raise exception 'Unknown period' using errcode = '22023';
  end if;

  select p.university_id, lower(trim(coalesce(p.college, ''))), p.academic_year
    into v_university, v_college, v_year
  from public.profiles as p
  where p.id = v_uid and p.role = 'student';

  if v_university is null or coalesce(v_college, '') = '' or v_year is null
     or not private.can_current_user_access_mcq() then
    return;
  end if;

  v_since := case when p_period = 'week' then private.leaderboard_week_start() end;

  return query
  with cohort as (
    select p.id, p.full_name
    from public.profiles as p
    where p.university_id = v_university
      and lower(trim(coalesce(p.college, ''))) = v_college
      and p.academic_year = v_year
      and p.role = 'student'
      and p.approved is true
      and p.mcq_access_enabled is true
  ),
  scored as (
    select answer.user_id, count(*)::integer as points
    from cohort
    join public.mcq_correct_answers as answer on answer.user_id = cohort.id
    where v_since is null or answer.first_correct_at >= v_since
    group by answer.user_id
  ),
  ranked as (
    select scored.user_id,
           scored.points,
           (rank() over (order by scored.points desc))::integer as place
    from scored
  ),
  picked as (
    select ranked.place, ranked.user_id, ranked.points
    from ranked
    where ranked.place <= v_limit or ranked.user_id = v_uid
    union all
    select null::integer, v_uid, 0
    where not exists (select 1 from ranked where ranked.user_id = v_uid)
  )
  select
    picked.place,
    case
      when picked.user_id = v_uid or hidden.user_id is null
        then private.leaderboard_display_name(cohort.full_name)
    end,
    picked.points,
    picked.user_id = v_uid,
    hidden.user_id is not null
  from picked
  join cohort on cohort.id = picked.user_id
  left join public.leaderboard_hidden as hidden on hidden.user_id = picked.user_id
  order by picked.place nulls last, cohort.full_name;
end;
$$;

-- Based on: ./supabase/migrations/20261115000000_mcq_weekly_winner_notifications.sql
create or replace function private.dispatch_mcq_weekly_winner_notifications(
  p_week_start timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  is_enabled boolean := true;
  current_wk_start timestamptz := private.leaderboard_week_start();
  target_wk_start timestamptz;
  target_wk_end timestamptz;
  start_cairo date;
  end_cairo date;
  week_label text;
  week_key text;
  inserted_count integer := 0;
begin
  select coalesce((payload ->> 'enabled')::boolean, true)
  into is_enabled
  from public.app_state
  where storage_key = 'g:weekly_winner_notifications';

  if coalesce(is_enabled, true) is false then
    return 0;
  end if;

  if p_week_start is null then
    target_wk_start := (current_wk_start at time zone 'Africa/Cairo' - interval '7 days')
      at time zone 'Africa/Cairo';
  else
    target_wk_start := private.leaderboard_week_start_for(p_week_start);
  end if;

  if target_wk_start is null or target_wk_start >= current_wk_start then
    return 0;
  end if;

  target_wk_end := (target_wk_start at time zone 'Africa/Cairo' + interval '7 days')
    at time zone 'Africa/Cairo';
  start_cairo := (target_wk_start at time zone 'Africa/Cairo')::date;
  end_cairo := (target_wk_end at time zone 'Africa/Cairo')::date - 1;
  week_key := to_char(start_cairo, 'YYYY-MM-DD');
  week_label := to_char(start_cairo, 'Mon FMDD') || ' - ' || to_char(end_cairo, 'Mon FMDD, YYYY');

  with cohort as (
    select
      p.id,
      p.university_id,
      lower(trim(coalesce(p.college, ''))) as college,
      p.academic_year
    from public.profiles p
    where p.role::text = 'student'
      and p.approved
      and p.mcq_access_enabled
      and p.university_id is not null
      and nullif(trim(coalesce(p.college, '')), '') is not null
      and p.academic_year is not null
      and private.is_mcq_eligible(p.role, p.university_id, p.college)
  ),
  scored as (
    select
      a.user_id,
      c.university_id,
      c.college,
      c.academic_year,
      count(*)::integer as points
    from public.mcq_correct_answers a
    join cohort c on c.id = a.user_id
    where a.first_correct_at >= target_wk_start
      and a.first_correct_at < target_wk_end
    group by a.user_id, c.university_id, c.college, c.academic_year
  ),
  ranked as (
    select
      s.user_id,
      s.academic_year,
      s.points,
      rank() over (
        partition by s.university_id, s.college, s.academic_year
        order by s.points desc
      )::integer as rnk
    from scored s
    where s.points > 0
  ),
  winners as (
    select
      r.user_id,
      r.academic_year,
      r.points,
      r.rnk,
      'mcq-weekly-winner::' || week_key || '::' || r.user_id::text as external_id
    from ranked r
    where r.rnk between 1 and 3
  )
  insert into public.notifications (
    external_id,
    recipient_user_id,
    title,
    message,
    target_route,
    created_by_name
  )
  select
    w.external_id,
    w.user_id,
    'Weekly Leaderboard Winner (#' || w.rnk || ')',
    'Congratulations! You finished #' || w.rnk || ' in Year ' || w.academic_year
      || ' for ' || week_label || ' with ' || w.points
      || case when w.points = 1 then ' point' else ' points' end
      || '. Contact MedBank for your prize!',
    'dashboard',
    'MedBank'
  from winners w
  where not exists (
    select 1
    from public.notifications n
    where n.external_id = w.external_id
  );

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

revoke all on function private.dispatch_mcq_weekly_winner_notifications(timestamptz)
  from public, anon, authenticated;

-- Based on: ../MedBank Website/supabase/migrations/20261009210100_video_course_audience.sql
create or replace function public.bootstrap_profile_from_auth_user_row()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  metadata jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  app_metadata jsonb := coalesce(new.raw_app_meta_data, '{}'::jsonb);
  email_text text := lower(trim(coalesce(new.email, '')));
  full_name_text text;
  phone_text text;
  year_text text;
  semester_text text;
  year_value integer := null;
  semester_value integer := null;
  provider_text text;
  university_text text;
  university_value uuid := null;
  college_value text := null;
  program_years_count smallint := null;
  program_semesters_per_year smallint := null;
  org_code text;
begin
  full_name_text := trim(coalesce(metadata->>'full_name', ''));
  if full_name_text = '' then
    full_name_text := trim(split_part(email_text, '@', 1));
  end if;
  if full_name_text = '' then
    full_name_text := 'Student';
  end if;

  phone_text := nullif(trim(coalesce(metadata->>'phone_number', metadata->>'phone', '')), '');

  year_text := trim(coalesce(metadata->>'academic_year', metadata->>'academicYear', ''));
  if year_text ~ '^[1-7]$' then
    year_value := year_text::integer;
  end if;

  semester_text := trim(coalesce(metadata->>'academic_semester', metadata->>'academicSemester', ''));
  if semester_text ~ '^[1-3]$' then
    semester_value := semester_text::integer;
  end if;

  provider_text := nullif(trim(coalesce(metadata->>'auth_provider', app_metadata->>'provider', '')), '');

  university_text := lower(trim(coalesce(metadata->>'university_id', metadata->>'universityId', '')));
  if university_text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select u.id into university_value
    from public.universities u
    where u.id = university_text::uuid and u.is_active;
  end if;

  college_value := lower(trim(coalesce(metadata->>'college', '')));
  if college_value !~ '^[a-z][a-z0-9_]{1,39}$' then
    college_value := null;
  elsif university_value is not null then
    select uc.years_count, uc.semesters_per_year
      into program_years_count, program_semesters_per_year
    from public.university_colleges uc
    where uc.university_id = university_value
      and uc.college_key = college_value
      and uc.is_active is true;

    if not found then
      college_value := null;
    else
      if year_value is not null and year_value > program_years_count then
        year_value := null;
      end if;
      if semester_value is not null and semester_value > program_semesters_per_year then
        semester_value := null;
      end if;
    end if;
  elsif not exists (
    select 1
    from public.university_colleges uc
    where uc.college_key = college_value
      and uc.is_active is true
  ) then
    college_value := null;
  end if;

  insert into public.profiles (
    id, full_name, email, phone, role, approved,
    academic_year, academic_semester, auth_provider, university_id, college
  ) values (
    new.id, full_name_text, email_text, phone_text,
    'student'::public.app_user_role, false,
    year_value, semester_value, provider_text, university_value, college_value
  )
  on conflict (id) do update
  set
    full_name = case
      when coalesce(trim(public.profiles.full_name), '') = '' then excluded.full_name
      else public.profiles.full_name
    end,
    email = case
      when coalesce(trim(public.profiles.email), '') = '' then excluded.email
      else public.profiles.email
    end,
    phone = coalesce(public.profiles.phone, excluded.phone),
    role = public.profiles.role,
    approved = public.profiles.approved,
    academic_year = coalesce(public.profiles.academic_year, excluded.academic_year),
    academic_semester = coalesce(public.profiles.academic_semester, excluded.academic_semester),
    auth_provider = coalesce(public.profiles.auth_provider, excluded.auth_provider),
    university_id = coalesce(public.profiles.university_id, excluded.university_id),
    college = coalesce(public.profiles.college, excluded.college);

  perform public.bootstrap_student_enrollments_from_auth_metadata(new.id, metadata);

  org_code := nullif(btrim(coalesce(metadata->>'organization_code', '')), '');
  if org_code is not null then
    begin
      perform private.join_organization_as(new.id, org_code);
    exception when others then
      null;
    end;
  end if;

  return new;
end;
$function$;

-- ============================================================================
-- 10. Copy an MCQ subject (course + topics + questions + choices) to a program
-- ============================================================================

create or replace function public.admin_copy_mcq_subject(
  p_course_id uuid,
  p_target_program_id uuid,
  p_academic_year smallint,
  p_academic_semester smallint,
  p_new_name text default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_source public.courses%rowtype;
  v_target_name text;
  v_new_course_id uuid;
begin
  if not coalesce(private.is_admin_user(), false)
     or not coalesce(private.admin_write_allowed('mcq'), false) then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  select *
    into v_source
  from public.courses c
  where c.id = p_course_id;

  if not found then
    raise exception 'Course not found' using errcode = 'P0002';
  end if;

  v_target_name := coalesce(nullif(btrim(p_new_name), ''), v_source.course_name);

  if exists (
    select 1
    from public.courses c
    where c.program_id = p_target_program_id
      and c.course_name = v_target_name
      and c.academic_year = p_academic_year
      and c.academic_semester = p_academic_semester
  ) then
    raise exception using errcode = '23505', message = 'SUBJECT_EXISTS';
  end if;

  begin
    insert into public.courses (
      program_id,
      course_code,
      course_name,
      academic_year,
      academic_semester,
      is_active
    )
    values (
      p_target_program_id,
      v_source.course_code,
      v_target_name,
      p_academic_year,
      p_academic_semester,
      false
    )
    returning id into v_new_course_id;
  exception when unique_violation then
    raise exception using errcode = '23505', message = 'SUBJECT_EXISTS';
  end;

  drop table if exists pg_temp._admin_copy_mcq_subject_questions;
  drop table if exists pg_temp._admin_copy_mcq_subject_topics;

  create temp table pg_temp._admin_copy_mcq_subject_topics (
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  create temp table pg_temp._admin_copy_mcq_subject_questions (
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  insert into pg_temp._admin_copy_mcq_subject_topics (old_id, new_id)
  select t.id, gen_random_uuid()
  from public.course_topics t
  where t.course_id = p_course_id;

  insert into public.course_topics (
    id,
    course_id,
    topic_name,
    sort_order,
    is_active
  )
  select
    tm.new_id,
    v_new_course_id,
    t.topic_name,
    t.sort_order,
    t.is_active
  from public.course_topics t
  join pg_temp._admin_copy_mcq_subject_topics tm on tm.old_id = t.id
  order by t.sort_order, t.id;

  insert into pg_temp._admin_copy_mcq_subject_questions (old_id, new_id)
  select q.id, gen_random_uuid()
  from public.questions q
  left join pg_temp._admin_copy_mcq_subject_topics tm on tm.old_id = q.topic_id
  where q.course_id = p_course_id
    and (q.topic_id is null or tm.new_id is not null);

  insert into public.questions (
    id,
    course_id,
    topic_id,
    status,
    stem,
    explanation,
    objective,
    difficulty,
    external_id,
    question_image_url,
    explanation_image_url,
    sort_order,
    author_id
  )
  select
    qm.new_id,
    v_new_course_id,
    tm.new_id,
    q.status,
    q.stem,
    q.explanation,
    q.objective,
    q.difficulty,
    null,
    q.question_image_url,
    q.explanation_image_url,
    q.sort_order,
    q.author_id
  from public.questions q
  join pg_temp._admin_copy_mcq_subject_questions qm on qm.old_id = q.id
  left join pg_temp._admin_copy_mcq_subject_topics tm on tm.old_id = q.topic_id
  order by q.sort_order, q.id;

  insert into public.question_choices (
    question_id,
    choice_label,
    choice_text,
    is_correct
  )
  select
    qm.new_id,
    qc.choice_label,
    qc.choice_text,
    qc.is_correct
  from public.question_choices qc
  join pg_temp._admin_copy_mcq_subject_questions qm on qm.old_id = qc.question_id
  order by qc.question_id, qc.choice_label, qc.id;

  drop table if exists pg_temp._admin_copy_mcq_subject_questions;
  drop table if exists pg_temp._admin_copy_mcq_subject_topics;

  return v_new_course_id;
end;
$function$;

revoke all on function public.admin_copy_mcq_subject(uuid, uuid, smallint, smallint, text)
  from public, anon;
grant execute on function public.admin_copy_mcq_subject(uuid, uuid, smallint, smallint, text)
  to authenticated;

notify pgrst, 'reload schema';
