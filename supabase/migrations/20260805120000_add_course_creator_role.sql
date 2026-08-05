-- ---------------------------------------------------------------------------
-- Course creators.
--
-- Adds a third role between student and admin. A creator owns the Video
-- Courses they author: they build the curriculum (modules, lessons,
-- materials) and read aggregate stats for their own course, but they can
-- never publish it themselves. Publishing is gated behind an admin review.
--
-- Creators are an APP-ONLY surface. The website exposes only the admin side
-- of this workflow (the approvals queue).
--
-- The `creator` enum label is added by the migration immediately before this
-- one. Every comparison below still casts the role to text rather than using
-- a `'creator'::app_user_role` literal, so this file is safe to re-run.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- Ownership + review state on the course row.
-- ---------------------------------------------------------------------------

alter table public.platform_courses
  add column if not exists owner_id uuid references public.profiles (id) on delete set null,
  add column if not exists review_status text not null default 'approved',
  add column if not exists submitted_at timestamptz,
  add column if not exists reviewed_by uuid references public.profiles (id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text;

-- Existing courses were all authored by admins and are already live, so they
-- stay approved. Only newly created creator courses enter the review flow.
update public.platform_courses
set owner_id = created_by
where owner_id is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'platform_courses_review_status_check'
  ) then
    alter table public.platform_courses
      add constraint platform_courses_review_status_check
      check (review_status in ('draft', 'pending', 'approved', 'rejected'));
  end if;
end;
$$;

create index if not exists platform_courses_owner_id_idx
  on public.platform_courses (owner_id);

create index if not exists platform_courses_review_status_idx
  on public.platform_courses (review_status)
  where review_status <> 'approved';

comment on column public.platform_courses.owner_id is
  'Creator who authors this course. Null for legacy admin-authored courses.';
comment on column public.platform_courses.review_status is
  'draft -> pending (creator submits) -> approved | rejected (admin decides). Only approved courses may be published.';

-- ---------------------------------------------------------------------------
-- Role helpers.
-- ---------------------------------------------------------------------------

create or replace function private.is_creator_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role::text = 'creator'
      and p.approved is true
  );
$$;

create or replace function private.owns_platform_course(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_courses c
    where c.id = target_course_id
      and c.owner_id = (select auth.uid())
  ) and private.is_creator_user();
$$;

-- Module/lesson children resolve ownership through their parent course.
create or replace function private.owns_platform_module(target_module_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_course_modules m
    where m.id = target_module_id
      and private.owns_platform_course(m.course_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- A creator may never publish or self-approve. Enforced with a trigger so we
-- can compare the old and new row, which an RLS WITH CHECK cannot do.
-- ---------------------------------------------------------------------------

create or replace function private.guard_platform_course_creator_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Only creators are constrained here. Admins, the service role, and any
  -- backend automation pass straight through; RLS already decides who may
  -- update the row at all.
  if private.is_admin_user() or not private.is_creator_user() then
    return new;
  end if;

  -- Ownership, review verdict, and audit columns are admin-only territory.
  if new.owner_id is distinct from old.owner_id
     or new.reviewed_by is distinct from old.reviewed_by
     or new.reviewed_at is distinct from old.reviewed_at
     or new.review_note is distinct from old.review_note then
    raise exception 'Only an admin can change course ownership or review decisions.'
      using errcode = '42501';
  end if;

  -- A creator can move draft/rejected -> pending (submit for review) and
  -- pending -> draft (withdraw). Everything else is the admin's call.
  if new.review_status is distinct from old.review_status
     and not (
       (old.review_status in ('draft', 'rejected') and new.review_status = 'pending')
       or (old.review_status = 'pending' and new.review_status = 'draft')
     ) then
    raise exception 'A course must be approved by an admin.'
      using errcode = '42501';
  end if;

  -- Publishing requires a standing approval.
  if new.is_published is true and old.review_status <> 'approved' then
    raise exception 'Only an approved course can be published.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists platform_courses_creator_guard on public.platform_courses;
create trigger platform_courses_creator_guard
  before update on public.platform_courses
  for each row
  execute function private.guard_platform_course_creator_update();

-- A course that loses approval must not stay visible to students.
create or replace function private.unpublish_platform_course_on_review_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.review_status <> 'approved' and new.is_published is true then
    new.is_published := false;
  end if;
  return new;
end;
$$;

drop trigger if exists platform_courses_unpublish_unapproved on public.platform_courses;
create trigger platform_courses_unpublish_unapproved
  before insert or update on public.platform_courses
  for each row
  execute function private.unpublish_platform_course_on_review_change();

-- ---------------------------------------------------------------------------
-- RLS: creators read and write their own course tree, nothing else.
-- ---------------------------------------------------------------------------

drop policy if exists platform_courses_select_creator on public.platform_courses;
create policy platform_courses_select_creator
  on public.platform_courses for select
  using (owner_id = (select auth.uid()) and private.is_creator_user());

drop policy if exists platform_courses_insert_creator on public.platform_courses;
create policy platform_courses_insert_creator
  on public.platform_courses for insert
  with check (
    owner_id = (select auth.uid())
    and private.is_creator_user()
    and review_status = 'draft'
    and is_published is false
  );

drop policy if exists platform_courses_update_creator on public.platform_courses;
create policy platform_courses_update_creator
  on public.platform_courses for update
  using (owner_id = (select auth.uid()) and private.is_creator_user())
  with check (owner_id = (select auth.uid()) and private.is_creator_user());

drop policy if exists platform_courses_delete_creator on public.platform_courses;
create policy platform_courses_delete_creator
  on public.platform_courses for delete
  using (
    owner_id = (select auth.uid())
    and private.is_creator_user()
    and review_status <> 'approved'
  );

drop policy if exists platform_modules_all_creator on public.platform_course_modules;
create policy platform_modules_all_creator
  on public.platform_course_modules for all
  using (private.owns_platform_course(course_id))
  with check (private.owns_platform_course(course_id));

drop policy if exists platform_lessons_all_creator on public.platform_course_lessons;
create policy platform_lessons_all_creator
  on public.platform_course_lessons for all
  using (private.owns_platform_course(course_id))
  with check (private.owns_platform_course(course_id));

drop policy if exists platform_resources_all_creator on public.platform_course_resources;
create policy platform_resources_all_creator
  on public.platform_course_resources for all
  using (private.owns_platform_course(course_id))
  with check (private.owns_platform_course(course_id));

-- ---------------------------------------------------------------------------
-- Creator submits for review; admin decides.
-- ---------------------------------------------------------------------------

create or replace function public.creator_submit_course_for_review(p_course_id uuid)
returns public.platform_courses
language plpgsql
security invoker
set search_path = ''
as $$
declare
  updated public.platform_courses;
begin
  update public.platform_courses
  set review_status = 'pending',
      submitted_at = now(),
      updated_at = now()
  where id = p_course_id
    and review_status in ('draft', 'rejected')
  returning * into updated;

  if updated.id is null then
    raise exception 'Course is not in a submittable state.' using errcode = 'P0002';
  end if;

  return updated;
end;
$$;

create or replace function public.admin_review_platform_course(
  p_course_id uuid,
  p_approved boolean,
  p_note text default null
)
returns public.platform_courses
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated public.platform_courses;
begin
  if not private.is_admin_user() then
    raise exception 'Only an admin can review courses.' using errcode = '42501';
  end if;

  update public.platform_courses
  set review_status = case when p_approved then 'approved' else 'rejected' end,
      reviewed_by = (select auth.uid()),
      reviewed_at = now(),
      review_note = nullif(btrim(coalesce(p_note, '')), ''),
      updated_at = now()
  where id = p_course_id
  returning * into updated;

  if updated.id is null then
    raise exception 'Course not found.' using errcode = 'P0002';
  end if;

  return updated;
end;
$$;

-- ---------------------------------------------------------------------------
-- Aggregate stats for one course. Owner or admin only.
--
-- Deliberately aggregate-only: creators see counts, never student identities.
-- ---------------------------------------------------------------------------

create or replace function public.creator_get_course_stats(p_course_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if not (private.is_admin_user() or private.owns_platform_course(p_course_id)) then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'course_id', p_course_id,
    'students', (
      select count(distinct e.user_id)
      from public.platform_course_enrollments e
      where e.course_id = p_course_id
    ),
    'students_full', (
      select count(distinct e.user_id)
      from public.platform_course_enrollments e
      where e.course_id = p_course_id and e.access_scope = 'full'
    ),
    'students_partial', (
      select count(distinct e.user_id)
      from public.platform_course_enrollments e
      where e.course_id = p_course_id and e.access_scope <> 'full'
    ),
    'pending_requests', (
      select count(*)
      from public.platform_course_enrollment_requests r
      where r.course_id = p_course_id and r.status = 'pending'
    ),
    'modules', (
      select count(*) from public.platform_course_modules m where m.course_id = p_course_id
    ),
    'lessons', (
      select count(*) from public.platform_course_lessons l where l.course_id = p_course_id
    ),
    'published_lessons', (
      select count(*)
      from public.platform_course_lessons l
      where l.course_id = p_course_id and l.is_published is true
    ),
    'materials', (
      select count(*) from public.platform_course_resources r where r.course_id = p_course_id
    ),
    'coupons', (
      select jsonb_build_object(
        'total', count(*),
        'full_course', count(*) filter (where c.coupon_type = 'full_course'),
        'module_access', count(*) filter (where c.coupon_type = 'module_access'),
        'redeemed', count(*) filter (where c.redeemed_at is not null),
        'unused', count(*) filter (
          where c.redeemed_at is null
            and c.is_enabled is true
            and (c.expires_at is null or c.expires_at > now())
        ),
        'expired', count(*) filter (
          where c.redeemed_at is null
            and c.expires_at is not null
            and c.expires_at <= now()
        ),
        'disabled', count(*) filter (where c.redeemed_at is null and c.is_enabled is false),
        'redemption_rate', case
          when count(*) = 0 then 0
          else round((count(*) filter (where c.redeemed_at is not null))::numeric * 100 / count(*), 1)
        end
      )
      from public.platform_course_coupons c
      where c.course_id = p_course_id
    )
  )
  into result;

  return result;
end;
$$;

revoke all on function public.creator_submit_course_for_review(uuid) from public;
revoke all on function public.admin_review_platform_course(uuid, boolean, text) from public;
revoke all on function public.creator_get_course_stats(uuid) from public;

grant execute on function public.creator_submit_course_for_review(uuid) to authenticated;
grant execute on function public.admin_review_platform_course(uuid, boolean, text) to authenticated;
grant execute on function public.creator_get_course_stats(uuid) to authenticated;



-- ---------------------------------------------------------------------------
-- Supabase's default privileges also grant EXECUTE on new public-schema
-- functions to `anon`, and `revoke ... from public` does not undo a direct
-- grant. Revoke explicitly: all three require a signed-in admin or course
-- owner, so anon must not reach them at all.
-- ---------------------------------------------------------------------------

revoke execute on function public.admin_review_platform_course(uuid, boolean, text) from anon;
revoke execute on function public.creator_get_course_stats(uuid) from anon;
revoke execute on function public.creator_submit_course_for_review(uuid) from anon;

commit;
