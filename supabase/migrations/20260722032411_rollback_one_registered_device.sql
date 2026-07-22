begin;

do $block$
declare
  target_table text;
begin
  foreach target_table in array array[
    'app_feature_flags', 'app_state', 'content_versions', 'course_topics', 'courses',
    'notification_reads', 'notifications', 'platform_course_announcements',
    'platform_course_enrollment_requests', 'platform_course_enrollments',
    'platform_course_lessons', 'platform_course_modules', 'platform_course_resources',
    'platform_course_suggestions', 'platform_courses', 'platform_lesson_progress',
    'profiles', 'question_choices', 'questions', 'test_block_items', 'test_blocks',
    'test_history_entries', 'test_responses', 'user_activity_sessions',
    'user_course_enrollments', 'user_presence'
  ]
  loop
    execute format('drop policy if exists device_session_gate on public.%I', target_table);
  end loop;
end;
$block$;

drop policy if exists device_session_gate on storage.objects;

create or replace function private.can_current_user_access_mcq()
returns boolean
language sql
stable
security definer
set search_path = public, private
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
        )
      )
  );
$$;

create or replace function private.can_current_user_access_courses()
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and (
        (p.role = 'admin' and p.approved is true)
        or (p.role = 'student' and p.courses_access_enabled is true)
      )
  );
$$;

create or replace function private.platform_suggestion_matches_current_profile(
  target_year integer,
  target_semester integer
)
returns boolean
language sql
security definer
set search_path = public, private
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'student'
      and p.courses_access_enabled is true
      and (
        (target_year is null and target_semester is null)
        or (target_year = p.academic_year and target_semester is null)
        or (target_year = p.academic_year and target_semester = p.academic_semester)
      )
  );
$$;

create or replace function private.can_select_platform_course(
  target_course_id uuid,
  target_enrollment_mode text,
  target_is_active boolean,
  target_is_published boolean
)
returns boolean
language sql
security definer
set search_path = public, private
as $$
  select not private.is_app_feature_enabled('courses_coming_soon')
    and exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'student'
        and p.courses_access_enabled is true
        and target_is_active is true
        and target_is_published is true
        and (
          exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = p.id and e.course_id = target_course_id
          )
          or exists (
            select 1
            from public.platform_course_suggestions s
            where s.course_id = target_course_id
              and s.is_active is true
              and (s.starts_at is null or s.starts_at <= now())
              and (s.ends_at is null or s.ends_at >= now())
              and (
                (s.target_academic_year is null and s.target_semester is null)
                or (s.target_academic_year = p.academic_year and s.target_semester is null)
                or (s.target_academic_year = p.academic_year and s.target_semester = p.academic_semester)
              )
          )
        )
    );
$$;

create or replace function private.register_push_token(
  p_token text,
  p_platform text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  clean_token text := btrim(coalesce(p_token, ''));
  clean_platform text := lower(btrim(coalesce(p_platform, '')));
  registered_id uuid;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if clean_token = '' or char_length(clean_token) > 4096 then
    raise exception 'Invalid push token';
  end if;
  if clean_platform not in ('android', 'ios') then
    raise exception 'Invalid push platform';
  end if;

  insert into public.push_device_tokens (user_id, token, platform)
  values (caller_id, clean_token, clean_platform)
  on conflict (token) do update
  set user_id = excluded.user_id,
      platform = excluded.platform,
      updated_at = now()
  returning id into registered_id;

  return registered_id;
end;
$$;

create or replace function private.unregister_push_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  delete from public.push_device_tokens
  where user_id = auth.uid()
    and token = btrim(coalesce(p_token, ''));
  get diagnostics deleted_count = row_count;
  return deleted_count > 0;
end;
$$;

create policy app_state_select_anon
on public.app_state
for select
to anon
using (
  storage_key like 'g:%'
  or storage_key = any (array[
    'mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites',
    'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'
  ]::text[])
);

create policy app_state_insert_anon
on public.app_state
for insert
to anon
with check (
  storage_key like 'g:%'
  or storage_key = any (array[
    'mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites',
    'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'
  ]::text[])
);

create policy app_state_update_anon
on public.app_state
for update
to anon
using (
  storage_key like 'g:%'
  or storage_key = any (array[
    'mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites',
    'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'
  ]::text[])
)
with check (
  storage_key like 'g:%'
  or storage_key = any (array[
    'mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites',
    'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'
  ]::text[])
);

drop function if exists public.admin_activate_user_device(uuid, text);
drop function if exists public.admin_revoke_user_device(uuid, text);
drop function if exists public.check_user_device(text, text, text);
drop function if exists public.claim_user_device(text, text, text);
drop function if exists private.admin_activate_user_device(uuid, text);
drop function if exists private.admin_revoke_user_device(uuid, text);
drop function if exists private.check_user_device(text, text, text);
drop function if exists private.claim_user_device(text, text, text);
drop function if exists private.current_session_has_active_device();
drop table if exists public.user_devices;

notify pgrst, 'reload schema';

commit;
