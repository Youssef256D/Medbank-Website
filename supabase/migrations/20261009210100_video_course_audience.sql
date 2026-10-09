-- Every video-course access rule asks `private.user_in_video_course_audience`.
--
-- Each function below is the live definition with the audience check added,
-- so a student removed from an organization loses that organization's
-- courses at once: the catalog, chapters, lessons, resources, materials,
-- videos, announcements, progress, quizzes, My Courses and new-lesson
-- notices. Bought ones included; that is the product decision, do not "fix"
-- it by letting an enrollment win.
--
-- Creators publish only to the organizations an admin made them a creator
-- member of, and only an admin makes a course public.
--
-- Sign-up also tries an organization code (auth metadata
-- `organization_code`) without ever failing the sign-up. The MCQ fields the
-- trigger already reads are unchanged.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. Catalog and access
-- ═══════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION private.can_select_platform_course(target_course_id uuid, target_enrollment_mode text, target_is_active boolean, target_is_published boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.is_active_platform_student()
    and target_is_active is true
    and target_is_published is true
    and private.video_course_audience_allows(target_course_id);
$function$;

CREATE OR REPLACE FUNCTION private.can_access_platform_lesson(target_lesson_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_course_lessons l
      join public.platform_course_modules m
        on m.id = l.module_id and m.course_id = l.course_id
      join public.platform_courses c on c.id = l.course_id
      where l.id = target_lesson_id
        and l.is_published is true
        and m.is_published is true
        and c.is_active is true
        and c.is_published is true
        and private.video_course_audience_allows(c.id)
        and (
          l.is_free_preview is true
          or exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = l.course_id
              and e.access_scope = 'full'
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = l.course_id
              and me.module_id = l.module_id
          )
        )
    )
    and private.platform_lesson_sequence_open(target_lesson_id);
$function$;

CREATE OR REPLACE FUNCTION private.has_any_platform_course_access(target_course_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.is_active_platform_student()
    and private.video_course_audience_allows(target_course_id)
    and (
      exists (
        select 1
        from public.platform_course_enrollments e
        where e.user_id = (select auth.uid())
          and e.course_id = target_course_id
      )
      or exists (
        select 1
        from public.platform_course_module_entitlements me
        where me.user_id = (select auth.uid())
          and me.course_id = target_course_id
      )
    );
$function$;

CREATE OR REPLACE FUNCTION private.has_full_platform_course_access(target_course_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.is_active_platform_student()
    and private.video_course_audience_allows(target_course_id)
    and exists (
      select 1
      from public.platform_course_enrollments e
      where e.user_id = (select auth.uid())
        and e.course_id = target_course_id
        and e.access_scope = 'full'
    );
$function$;

CREATE OR REPLACE FUNCTION private.has_platform_course_access(target_course_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_courses c
      where c.id = target_course_id
        and c.is_active is true
        and c.is_published is true
        and private.video_course_audience_allows(c.id)
        and (
          exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = c.id
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = c.id
          )
        )
    );
$function$;

CREATE OR REPLACE FUNCTION private.has_platform_module_access(target_module_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_course_modules m
      join public.platform_courses c on c.id = m.course_id
      where m.id = target_module_id
        and m.is_published is true
        and c.is_active is true
        and c.is_published is true
        and private.video_course_audience_allows(c.id)
        and (
          exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = m.course_id
              and e.access_scope = 'full'
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = m.course_id
              and me.module_id = m.id
          )
        )
    );
$function$;

-- Progression (get_my_platform_course_progression, the lesson sequence)
-- reads this, so a removed member's chapters read as not owned.
CREATE OR REPLACE FUNCTION private.student_owns_platform_module(target_module_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.platform_course_modules m
    where m.id = target_module_id
      and private.video_course_audience_allows(m.course_id)
  )
  and (
    exists (
      select 1
      from public.platform_course_modules m
      join public.platform_course_enrollments e
        on e.course_id = m.course_id
       and e.user_id = (select auth.uid())
       and e.access_scope = 'full'
      where m.id = target_module_id
    ) or exists (
      select 1
      from public.platform_course_module_entitlements me
      where me.module_id = target_module_id
        and me.user_id = (select auth.uid())
    )
  );
$function$;

-- My Courses: a course the student can no longer see is left out, rather
-- than listed as an empty card.
CREATE OR REPLACE FUNCTION public.get_my_platform_course_access()
 RETURNS TABLE(course_id uuid, access_scope text, access_source text, module_ids uuid[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with accessible_courses as (
    select e.course_id
    from public.platform_course_enrollments e
    where e.user_id = (select auth.uid())
    union
    select me.course_id
    from public.platform_course_module_entitlements me
    where me.user_id = (select auth.uid())
  )
  select
    ac.course_id,
    case when bool_or(coalesce(e.access_scope = 'full', false)) then 'full' else 'partial' end,
    case
      when bool_or(coalesce(e.access_scope = 'full', false))
        then max(e.access_source) filter (where e.access_scope = 'full')
      else 'coupon'
    end,
    case
      when bool_or(coalesce(e.access_scope = 'full', false)) then coalesce((
        select array_agg(m.id order by m.position, m.id)
        from public.platform_course_modules m
        where m.course_id = ac.course_id and m.is_published is true
      ), '{}'::uuid[])
      else coalesce((
        select array_agg(me.module_id order by m.position, me.module_id)
        from public.platform_course_module_entitlements me
        join public.platform_course_modules m on m.id = me.module_id
        where me.user_id = (select auth.uid())
          and me.course_id = ac.course_id
          and m.is_published is true
      ), '{}'::uuid[])
    end
  from accessible_courses ac
  left join public.platform_course_enrollments e
    on e.user_id = (select auth.uid()) and e.course_id = ac.course_id
  where (select auth.uid()) is not null
    and private.video_course_audience_allows(ac.course_id)
  group by ac.course_id;
$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 2. Coupons: a coupon for a course the student cannot see is refused
-- ═══════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.redeem_platform_course_coupon(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor_id uuid := (select auth.uid());
  normalized_code text := private.normalize_platform_coupon_code(p_code);
  coupon_row public.platform_course_coupons%rowtype;
  course_row public.platform_courses%rowtype;
  module_ids uuid[] := '{}'::uuid[];
  module_titles text[] := '{}'::text[];
  mapped_module_count integer := 0;
  valid_module_count integer := 0;
  already_full boolean := false;
  already_module_count integer := 0;
begin
  if actor_id is null then
    return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
  end if;
  if length(normalized_code) < 20 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_COUPON');
  end if;

  begin
    select * into coupon_row
    from public.platform_course_coupons c
    where c.code_hash = extensions.digest(normalized_code, 'sha256')
    for update;

    if not found then
      return jsonb_build_object('ok', false, 'code', 'INVALID_COUPON');
    end if;
    if coupon_row.redeemed_at is not null then
      return jsonb_build_object('ok', false, 'code', 'COUPON_ALREADY_USED');
    end if;
    if coupon_row.is_enabled is not true then
      return jsonb_build_object('ok', false, 'code', 'COUPON_DISABLED');
    end if;
    if coupon_row.expires_at is not null and coupon_row.expires_at <= now() then
      return jsonb_build_object('ok', false, 'code', 'COUPON_EXPIRED');
    end if;
    if not exists (
      select 1 from public.profiles p
      where p.id = actor_id
        and p.role = 'student'
        and p.approved is true
        and p.courses_access_enabled is true
    ) then
      return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
    end if;

    select * into course_row
    from public.platform_courses c
    where c.id = coupon_row.course_id;
    -- A course outside the student's organizations answers exactly like an
    -- unavailable one, so a coupon does not reveal that the course exists.
    if not found or course_row.is_active is not true or course_row.is_published is not true
       or not private.user_in_video_course_audience(actor_id, course_row.id) then
      return jsonb_build_object('ok', false, 'code', 'COURSE_UNAVAILABLE');
    end if;

    select exists (
      select 1
      from public.platform_course_enrollments e
      where e.user_id = actor_id
        and e.course_id = coupon_row.course_id
        and e.access_scope = 'full'
    ) into already_full;

    if coupon_row.coupon_type = 'module_access' then
      select count(*) into mapped_module_count
      from public.platform_course_coupon_modules cm
      where cm.coupon_id = coupon_row.id;

      select
        coalesce(array_agg(m.id order by m.position, m.id), '{}'::uuid[]),
        coalesce(array_agg(m.title order by m.position, m.id), '{}'::text[]),
        count(*)
      into module_ids, module_titles, valid_module_count
      from public.platform_course_coupon_modules cm
      join public.platform_course_modules m on m.id = cm.module_id
      where cm.coupon_id = coupon_row.id
        and m.course_id = coupon_row.course_id
        and m.is_published is true;

      if mapped_module_count = 0 or valid_module_count <> mapped_module_count then
        return jsonb_build_object('ok', false, 'code', 'MODULE_UNAVAILABLE');
      end if;
      if already_full then
        return jsonb_build_object('ok', false, 'code', 'ALREADY_HAS_ACCESS');
      end if;

      select count(*) into already_module_count
      from public.platform_course_module_entitlements me
      where me.user_id = actor_id
        and me.course_id = coupon_row.course_id
        and me.module_id = any(module_ids);

      if already_module_count = cardinality(module_ids) then
        return jsonb_build_object('ok', false, 'code', 'ALREADY_HAS_ACCESS');
      end if;

      insert into public.platform_course_enrollments (
        user_id, course_id, assigned_by, access_scope, access_source, source_coupon_id
      ) values (
        actor_id, coupon_row.course_id, null, 'partial', 'coupon', coupon_row.id
      )
      on conflict (user_id, course_id) do update
      set
        access_scope = case
          when public.platform_course_enrollments.access_scope = 'full' then 'full'
          else 'partial'
        end,
        access_source = case
          when public.platform_course_enrollments.access_scope = 'full'
            then public.platform_course_enrollments.access_source
          else 'coupon'
        end,
        source_coupon_id = case
          when public.platform_course_enrollments.access_scope = 'full'
            then public.platform_course_enrollments.source_coupon_id
          else coupon_row.id
        end;

      insert into public.platform_course_module_entitlements (
        user_id, course_id, module_id, grant_source, source_coupon_id, granted_by
      )
      select actor_id, coupon_row.course_id, module_id, 'coupon', coupon_row.id, null
      from unnest(module_ids) as module_id
      on conflict (user_id, module_id) do nothing;
    else
      if already_full then
        return jsonb_build_object('ok', false, 'code', 'ALREADY_HAS_ACCESS');
      end if;

      insert into public.platform_course_enrollments (
        user_id, course_id, assigned_by, access_scope, access_source, source_coupon_id
      ) values (
        actor_id, coupon_row.course_id, null, 'full', 'coupon', coupon_row.id
      )
      on conflict (user_id, course_id) do update
      set access_scope = 'full', access_source = 'coupon', source_coupon_id = coupon_row.id;

      select
        coalesce(array_agg(m.id order by m.position, m.id), '{}'::uuid[]),
        coalesce(array_agg(m.title order by m.position, m.id), '{}'::text[])
      into module_ids, module_titles
      from public.platform_course_modules m
      where m.course_id = coupon_row.course_id and m.is_published is true;
    end if;

    insert into public.platform_course_coupon_redemptions (
      coupon_id, user_id, course_id, access_type, module_ids
    ) values (
      coupon_row.id, actor_id, coupon_row.course_id, coupon_row.coupon_type, module_ids
    );

    update public.platform_course_coupons
    set redeemed_by = actor_id, redeemed_at = now()
    where id = coupon_row.id;

    return jsonb_build_object(
      'ok', true,
      'code', 'SUCCESS',
      'course_id', course_row.id,
      'course_name', course_row.course_name,
      'access_type', coupon_row.coupon_type,
      'module_ids', to_jsonb(module_ids),
      'module_titles', to_jsonb(module_titles)
    );
  exception
    when unique_violation then
      return jsonb_build_object('ok', false, 'code', 'COUPON_ALREADY_USED');
    when others then
      return jsonb_build_object('ok', false, 'code', 'REDEMPTION_FAILED');
  end;
end;
$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 3. New-lesson notices reach only the course's audience
-- ═══════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION private.notify_students_on_new_lesson()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  ) as student
  where private.user_in_video_course_audience(student.user_id, new.course_id);

  return new;
end;
$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. Creators publish to their organizations; only an admin goes public
-- ═══════════════════════════════════════════════════════════════════════

-- An organization-only course cannot go live with nobody to show it to.
create or replace function private.guard_platform_course_audience()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.visibility = 'organization'
     and new.is_published is true
     and not exists (
       select 1 from public.platform_course_organizations co where co.course_id = new.id
     ) then
    raise exception 'Choose at least one organization before publishing an organization-only course.'
      using errcode = '23514';
  end if;
  return new;
end;
$function$;

-- A creator's course is organization-only from the start, whatever the insert
-- says (the column default stays 'public' for admin-authored courses), and a
-- creator can never make it public.
create or replace function private.guard_creator_course_visibility()
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
    new.visibility := 'organization';
    return new;
  end if;

  if new.visibility = 'public' and old.visibility is distinct from 'public' then
    raise exception 'Only an admin can make a course public.'
      using errcode = '42501';
  end if;

  return new;
end;
$function$;

revoke all on function private.guard_platform_course_audience() from public, anon, authenticated;
revoke all on function private.guard_creator_course_visibility() from public, anon, authenticated;

-- Named so the creator trigger sorts first and the audience check sees the
-- visibility it settled on.
create trigger trg_platform_courses_creator_visibility
  before insert or update of visibility on public.platform_courses
  for each row execute function private.guard_creator_course_visibility();

create trigger trg_platform_courses_guard_audience
  before insert or update of visibility, is_published on public.platform_courses
  for each row execute function private.guard_platform_course_audience();

CREATE OR REPLACE FUNCTION public.creator_submit_course_for_review(p_course_id uuid)
 RETURNS platform_courses
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  updated public.platform_courses;
begin
  if exists (
    select 1
    from public.platform_courses c
    where c.id = p_course_id
      and c.visibility = 'organization'
      and not exists (
        select 1 from public.platform_course_organizations co where co.course_id = c.id
      )
  ) then
    raise exception 'Choose at least one organization before submitting this course.'
      using errcode = '23514';
  end if;

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
$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 5. Suggestions target an organization
-- ═══════════════════════════════════════════════════════════════════════

alter table public.platform_course_suggestions
  add column target_organization_id uuid references public.organizations (id) on delete set null;
create index platform_course_suggestions_target_organization_idx
  on public.platform_course_suggestions (target_organization_id);

drop policy if exists platform_suggestions_select_student_visible on public.platform_course_suggestions;
create policy platform_suggestions_select_student_visible on public.platform_course_suggestions
  for select to authenticated
  using (
    is_active is true
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at >= now())
    and private.can_select_platform_course_by_id(course_id)
    and (target_organization_id is null or private.is_organization_member(target_organization_id))
  );

-- ═══════════════════════════════════════════════════════════════════════
-- 6. Sign-up tries an organization code
-- ═══════════════════════════════════════════════════════════════════════

-- The live trigger, unchanged for the MCQ fields, plus: the code typed on the
-- sign-up form (auth metadata `organization_code`) is tried once. A wrong code
-- never fails the sign-up; the student can add it later from Profile.
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
