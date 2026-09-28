-- Universities and colleges decide who may use the MCQ Bank.
--
-- The MCQ Bank only has questions for Medicine at October 6 University, so a
-- student is eligible for it only when their university offers the bank
-- (`universities.mcq_bank_available`) AND their college is 'medicine'.
-- Everyone else still gets Video Courses.
--
-- Eligibility is enforced as an invariant on `profiles.mcq_access_enabled`
-- (trigger below) rather than only inside `can_current_user_access_mcq`, so
-- every client that already reads that flag — the website, and app builds
-- released before this change — hides the MCQ Bank correctly without an
-- update. The access function checks eligibility as well, as a second line.
--
-- Existing students are backfilled to October 6 University / Medicine: the
-- bank has only ever served them, and nobody who studies today may lose it.

-- ---------------------------------------------------------------------------
-- Universities (admin-managed list shown at sign-up)
-- ---------------------------------------------------------------------------
create table if not exists public.universities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_ar text,
  mcq_bank_available boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint universities_name_not_blank_ck check (length(trim(name)) >= 2)
);

create unique index if not exists universities_name_lower_uniq
  on public.universities (lower(trim(name)));

drop trigger if exists trg_universities_updated_at on public.universities;
create trigger trg_universities_updated_at
  before update on public.universities
  for each row execute function public.set_updated_at();

alter table public.universities enable row level security;

drop policy if exists universities_select on public.universities;
create policy universities_select on public.universities
  for select to anon, authenticated
  using (is_active or (select private.is_admin_user()));

drop policy if exists universities_admin_insert on public.universities;
create policy universities_admin_insert on public.universities
  for insert to authenticated
  with check ((select private.is_admin_user()));

drop policy if exists universities_admin_update on public.universities;
create policy universities_admin_update on public.universities
  for update to authenticated
  using ((select private.is_admin_user()))
  with check ((select private.is_admin_user()));

drop policy if exists universities_admin_delete on public.universities;
create policy universities_admin_delete on public.universities
  for delete to authenticated
  using ((select private.is_admin_user()));

grant select on public.universities to anon, authenticated;
grant insert, update, delete on public.universities to authenticated;

insert into public.universities (name, name_ar, mcq_bank_available, sort_order)
values ('October 6 University', 'جامعة 6 أكتوبر', true, 0)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Profile columns
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists university_id uuid
    references public.universities (id) on delete restrict,
  add column if not exists college text;

alter table public.profiles drop constraint if exists profiles_college_ck;
alter table public.profiles add constraint profiles_college_ck check (
  college is null or college in (
    'medicine', 'dentistry', 'pharmacy', 'nursing',
    'physical_therapy', 'applied_health_sciences', 'other'
  )
);

create index if not exists profiles_university_id_idx
  on public.profiles (university_id);

-- ---------------------------------------------------------------------------
-- Eligibility
-- ---------------------------------------------------------------------------
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
    else target_college = 'medicine' and exists (
      select 1 from public.universities u
      where u.id = target_university_id and u.mcq_bank_available is true
    )
  end;
$$;

-- Keeps `mcq_access_enabled` honest:
--   * an ineligible student can never hold it;
--   * becoming eligible turns it on (the column default is on for everyone);
--   * a student editing their own row can never set it themselves.
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
begin
  if tg_op = 'UPDATE' and caller is not null and caller = new.id
     and not caller_is_admin then
    new.mcq_access_enabled := old.mcq_access_enabled;
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

  eligible := private.is_mcq_eligible(new.role, new.university_id, new.college);
  if tg_op = 'UPDATE' then
    was_eligible := private.is_mcq_eligible(old.role, old.university_id, old.college);
  end if;

  if not eligible then
    new.mcq_access_enabled := false;
  elsif tg_op = 'UPDATE' and not was_eligible then
    new.mcq_access_enabled := true;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Backfill BEFORE the trigger exists: every current profile is O6U medicine.
-- ---------------------------------------------------------------------------
update public.profiles p
set
  university_id = coalesce(p.university_id, (
    select u.id from public.universities u
    where lower(trim(u.name)) = 'october 6 university'
  )),
  college = coalesce(p.college, 'medicine')
where p.university_id is null or p.college is null;

drop trigger if exists trg_profiles_mcq_eligibility on public.profiles;
create trigger trg_profiles_mcq_eligibility
  before insert or update on public.profiles
  for each row execute function private.enforce_profile_mcq_eligibility();

-- Changing a university's MCQ availability re-decides its students.
create or replace function private.sync_university_mcq_availability()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  if new.mcq_bank_available is distinct from old.mcq_bank_available then
    update public.profiles p
    set mcq_access_enabled = (new.mcq_bank_available and p.college = 'medicine')
    where p.university_id = new.id
      and p.role = 'student'::public.app_user_role;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_universities_sync_mcq on public.universities;
create trigger trg_universities_sync_mcq
  after update of mcq_bank_available on public.universities
  for each row execute function private.sync_university_mcq_availability();

-- ---------------------------------------------------------------------------
-- MCQ access: the flag AND eligibility.
-- ---------------------------------------------------------------------------
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
          and p.college = 'medicine'
          and exists (
            select 1 from public.universities u
            where u.id = p.university_id and u.mcq_bank_available is true
          )
        )
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- Own-profile updates: university/college are chosen during onboarding (or
-- filled in once if missing) and are admin-only after approval. The MCQ flag
-- is now owned by the trigger above, so it is no longer compared here.
-- ---------------------------------------------------------------------------
create or replace function private.can_update_own_profile_v2(
  target_id uuid,
  target_role public.app_user_role,
  target_approved boolean,
  target_year smallint,
  target_semester smallint,
  target_courses_access_enabled boolean,
  target_university_id uuid,
  target_college text
)
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
      and p.id = target_id
      and p.role = target_role
      and p.approved is not distinct from target_approved
      and p.courses_access_enabled is not distinct from target_courses_access_enabled
      and (
        p.approved is not true
        or (
          p.academic_year is not distinct from target_year
          and p.academic_semester is not distinct from target_semester
        )
      )
      and (
        p.approved is not true
        or p.university_id is null
        or p.university_id is not distinct from target_university_id
      )
      and (
        p.approved is not true
        or p.college is null
        or p.college is not distinct from target_college
      )
  );
$$;

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update
  using (
    (select private.is_admin_user())
    or (id = (select auth.uid()) and role = 'student'::public.app_user_role)
  )
  with check (
    (select private.is_admin_user())
    or private.can_update_own_profile_v2(
      id, role, approved, academic_year, academic_semester,
      courses_access_enabled, university_id, college
    )
  );

-- ---------------------------------------------------------------------------
-- Sign-up metadata: carry university_id / college into the profile.
-- ---------------------------------------------------------------------------
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
  if year_text ~ '^[1-5]$' then
    year_value := year_text::integer;
  end if;

  semester_text := trim(coalesce(metadata->>'academic_semester', metadata->>'academicSemester', ''));
  if semester_text ~ '^[12]$' then
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
  if college_value not in (
    'medicine', 'dentistry', 'pharmacy', 'nursing',
    'physical_therapy', 'applied_health_sciences', 'other'
  ) then
    college_value := null;
  end if;

  insert into public.profiles (
    id,
    full_name,
    email,
    phone,
    role,
    approved,
    academic_year,
    academic_semester,
    auth_provider,
    university_id,
    college
  ) values (
    new.id,
    full_name_text,
    email_text,
    phone_text,
    'student'::public.app_user_role,
    false,
    year_value,
    semester_value,
    provider_text,
    university_value,
    college_value
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
    -- Never demote an existing admin; never force-promote from this bootstrap.
    role = public.profiles.role,
    approved = public.profiles.approved,
    academic_year = coalesce(public.profiles.academic_year, excluded.academic_year),
    academic_semester = coalesce(public.profiles.academic_semester, excluded.academic_semester),
    auth_provider = coalesce(public.profiles.auth_provider, excluded.auth_provider),
    university_id = coalesce(public.profiles.university_id, excluded.university_id),
    college = coalesce(public.profiles.college, excluded.college);

  perform public.bootstrap_student_enrollments_from_auth_metadata(new.id, metadata);

  return new;
end;
$function$;

drop function if exists private.can_update_own_profile(
  uuid, public.app_user_role, boolean, smallint, smallint, boolean, boolean
);
