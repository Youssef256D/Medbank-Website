begin;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create table public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_id text not null,
  device_name text not null,
  platform text not null,
  status text not null default 'blocked',
  auth_session_id uuid references auth.sessions(id) on delete set null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references public.profiles(id) on delete set null,
  constraint user_devices_user_device_key unique (user_id, device_id),
  constraint user_devices_device_id_not_blank check (btrim(device_id) <> ''),
  constraint user_devices_device_id_length check (char_length(device_id) <= 255),
  constraint user_devices_device_name_not_blank check (btrim(device_name) <> ''),
  constraint user_devices_device_name_length check (char_length(device_name) <= 200),
  constraint user_devices_platform_not_blank check (btrim(platform) <> ''),
  constraint user_devices_platform_length check (char_length(platform) <= 64),
  constraint user_devices_status_check check (status in ('active', 'blocked', 'revoked')),
  constraint user_devices_revocation_state_check check (
    (status = 'revoked' and revoked_at is not null)
    or (status <> 'revoked' and revoked_at is null and revoked_by is null)
  )
);

-- Admins are exempt and do not need device rows. For every non-admin account,
-- this index is the final concurrency backstop after the per-user advisory lock.
create unique index user_devices_one_active_per_user_idx
  on public.user_devices (user_id)
  where status = 'active';

create index user_devices_user_last_seen_idx
  on public.user_devices (user_id, last_seen_at desc);

create index user_devices_active_user_session_idx
  on public.user_devices (user_id, auth_session_id)
  where status = 'active' and auth_session_id is not null;

create index user_devices_auth_session_idx
  on public.user_devices (auth_session_id)
  where auth_session_id is not null;

create index user_devices_revoked_by_idx
  on public.user_devices (revoked_by)
  where revoked_by is not null;

alter table public.user_devices enable row level security;
revoke all on table public.user_devices from public, anon, authenticated;
grant select on table public.user_devices to authenticated;
grant select, insert, update, delete on table public.user_devices to service_role;

create policy user_devices_select_admin
on public.user_devices
for select
to authenticated
using ((select private.is_admin_user()));

create or replace function private.current_session_has_active_device()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select case
    when (select auth.uid()) is null then false
    when exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'admin'::public.app_user_role
    ) then true
    when coalesce((select auth.jwt()->>'session_id'), '') !~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then false
    else exists (
      select 1
      from public.user_devices d
      where d.user_id = (select auth.uid())
        and d.status = 'active'
        and d.auth_session_id = ((select auth.jwt()->>'session_id'))::uuid
    )
  end;
$function$;

revoke all on function private.current_session_has_active_device() from public, anon;
grant execute on function private.current_session_has_active_device() to authenticated, service_role;

create or replace function private.claim_user_device(
  p_device_id text,
  p_device_name text,
  p_platform text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_session_id_text text := coalesce(auth.jwt()->>'session_id', '');
  v_session_id uuid;
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_device_name text := left(btrim(coalesce(p_device_name, '')), 200);
  v_platform text := left(lower(btrim(coalesce(p_platform, ''))), 64);
  v_existing public.user_devices%rowtype;
  v_active public.user_devices%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.id = v_user_id and p.role = 'admin'::public.app_user_role
  ) then
    return jsonb_build_object('status', 'allowed');
  end if;

  if v_session_id_text !~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'A valid Supabase Auth session is required' using errcode = '42501';
  end if;
  v_session_id := v_session_id_text::uuid;

  if v_device_id = '' or char_length(v_device_id) > 255 then
    raise exception 'A valid device_id is required';
  end if;
  if v_device_name = '' then
    v_device_name := 'Unknown device';
  end if;
  if v_platform = '' then
    v_platform := 'unknown';
  end if;

  -- Serialize every claim for this user. The transaction-level lock is released
  -- automatically and prevents two simultaneous first claims from both winning.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));

  select * into v_existing
  from public.user_devices d
  where d.user_id = v_user_id and d.device_id = v_device_id
  for update;

  select * into v_active
  from public.user_devices d
  where d.user_id = v_user_id and d.status = 'active'
  limit 1
  for update;

  if v_existing.id is not null and v_existing.status = 'revoked' then
    update public.user_devices
    set device_name = v_device_name,
        platform = v_platform,
        last_seen_at = now()
    where id = v_existing.id;
    return jsonb_build_object(
      'status', 'revoked',
      'active_device_name', coalesce(v_active.device_name, v_existing.device_name, v_device_name)
    );
  end if;

  if v_existing.id is not null and v_existing.status = 'active' then
    update public.user_devices
    set device_name = v_device_name,
        platform = v_platform,
        auth_session_id = v_session_id,
        last_seen_at = now()
    where id = v_existing.id;
    return jsonb_build_object('status', 'allowed');
  end if;

  if v_active.id is not null then
    if v_existing.id is null then
      insert into public.user_devices (
        user_id, device_id, device_name, platform, status, auth_session_id
      ) values (
        v_user_id, v_device_id, v_device_name, v_platform, 'blocked', v_session_id
      );
    else
      update public.user_devices
      set device_name = v_device_name,
          platform = v_platform,
          auth_session_id = v_session_id,
          last_seen_at = now()
      where id = v_existing.id;
    end if;
    return jsonb_build_object(
      'status', 'another_device_active',
      'active_device_name', v_active.device_name
    );
  end if;

  -- A previously blocked device never promotes itself, even if an admin has
  -- revoked the old active device. Only the explicit admin action can do that.
  if v_existing.id is not null then
    update public.user_devices
    set device_name = v_device_name,
        platform = v_platform,
        auth_session_id = v_session_id,
        last_seen_at = now()
    where id = v_existing.id;
    return jsonb_build_object(
      'status', 'another_device_active',
      'active_device_name', coalesce(v_existing.device_name, v_device_name)
    );
  end if;

  insert into public.user_devices (
    user_id, device_id, device_name, platform, status, auth_session_id
  ) values (
    v_user_id, v_device_id, v_device_name, v_platform, 'active', v_session_id
  );
  return jsonb_build_object('status', 'allowed');
end;
$function$;

create or replace function private.check_user_device(
  p_device_id text,
  p_device_name text,
  p_platform text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_session_id_text text := coalesce(auth.jwt()->>'session_id', '');
  v_session_id uuid;
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_device_name text := left(btrim(coalesce(p_device_name, '')), 200);
  v_platform text := left(lower(btrim(coalesce(p_platform, ''))), 64);
  v_existing public.user_devices%rowtype;
  v_active public.user_devices%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.id = v_user_id and p.role = 'admin'::public.app_user_role
  ) then
    return jsonb_build_object('status', 'allowed');
  end if;

  if v_session_id_text !~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'A valid Supabase Auth session is required' using errcode = '42501';
  end if;
  v_session_id := v_session_id_text::uuid;

  if v_device_id = '' or char_length(v_device_id) > 255 then
    raise exception 'A valid device_id is required';
  end if;
  if v_device_name = '' then
    v_device_name := 'Unknown device';
  end if;
  if v_platform = '' then
    v_platform := 'unknown';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));

  select * into v_existing
  from public.user_devices d
  where d.user_id = v_user_id and d.device_id = v_device_id
  for update;

  select * into v_active
  from public.user_devices d
  where d.user_id = v_user_id and d.status = 'active'
  limit 1
  for update;

  if v_existing.id is not null and v_existing.status = 'revoked' then
    update public.user_devices
    set device_name = v_device_name,
        platform = v_platform,
        last_seen_at = now()
    where id = v_existing.id;
    return jsonb_build_object(
      'status', 'revoked',
      'active_device_name', coalesce(v_active.device_name, v_existing.device_name, v_device_name)
    );
  end if;

  if v_existing.id is not null
     and v_existing.status = 'active'
     and v_existing.auth_session_id = v_session_id then
    update public.user_devices
    set device_name = v_device_name,
        platform = v_platform,
        last_seen_at = now()
    where id = v_existing.id;
    return jsonb_build_object('status', 'allowed');
  end if;

  if v_existing.id is null then
    insert into public.user_devices (
      user_id, device_id, device_name, platform, status, auth_session_id
    ) values (
      v_user_id, v_device_id, v_device_name, v_platform, 'blocked', v_session_id
    );
  elsif v_existing.status = 'blocked' then
    update public.user_devices
    set device_name = v_device_name,
        platform = v_platform,
        auth_session_id = v_session_id,
        last_seen_at = now()
    where id = v_existing.id;
  end if;

  return jsonb_build_object(
    'status', 'another_device_active',
    'active_device_name', coalesce(v_active.device_name, v_existing.device_name, v_device_name)
  );
end;
$function$;

create or replace function private.admin_revoke_user_device(
  p_user_id uuid,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := auth.uid();
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_updated public.user_devices%rowtype;
begin
  if v_admin_id is null or not private.is_admin_user() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_user_id is null or v_device_id = '' then
    raise exception 'A user and device are required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

  update public.user_devices
  set status = 'revoked',
      revoked_at = now(),
      revoked_by = v_admin_id
  where user_id = p_user_id and device_id = v_device_id
  returning * into v_updated;

  if v_updated.id is null then
    raise exception 'Device not found';
  end if;

  return jsonb_build_object('ok', true, 'status', v_updated.status);
end;
$function$;

create or replace function private.admin_activate_user_device(
  p_user_id uuid,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := auth.uid();
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_target public.user_devices%rowtype;
begin
  if v_admin_id is null or not private.is_admin_user() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_user_id is null or v_device_id = '' then
    raise exception 'A user and device are required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

  select * into v_target
  from public.user_devices d
  where d.user_id = p_user_id and d.device_id = v_device_id
  for update;

  if v_target.id is null then
    raise exception 'Device not found';
  end if;
  if v_target.status <> 'blocked' then
    raise exception 'Only a blocked device can be made active';
  end if;

  update public.user_devices
  set status = 'revoked',
      revoked_at = now(),
      revoked_by = v_admin_id
  where user_id = p_user_id and status = 'active';

  update public.user_devices
  set status = 'active',
      revoked_at = null,
      revoked_by = null
  where id = v_target.id;

  return jsonb_build_object('ok', true, 'status', 'active');
end;
$function$;

revoke all on function private.claim_user_device(text, text, text) from public, anon, authenticated;
revoke all on function private.check_user_device(text, text, text) from public, anon, authenticated;
revoke all on function private.admin_revoke_user_device(uuid, text) from public, anon, authenticated;
revoke all on function private.admin_activate_user_device(uuid, text) from public, anon, authenticated;
grant execute on function private.claim_user_device(text, text, text) to authenticated;
grant execute on function private.check_user_device(text, text, text) to authenticated;
grant execute on function private.admin_revoke_user_device(uuid, text) to authenticated;
grant execute on function private.admin_activate_user_device(uuid, text) to authenticated;

create or replace function public.claim_user_device(
  p_device_id text,
  p_device_name text,
  p_platform text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.claim_user_device(p_device_id, p_device_name, p_platform);
$function$;

create or replace function public.check_user_device(
  p_device_id text,
  p_device_name text,
  p_platform text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.check_user_device(p_device_id, p_device_name, p_platform);
$function$;

create or replace function public.admin_revoke_user_device(
  p_user_id uuid,
  p_device_id text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.admin_revoke_user_device(p_user_id, p_device_id);
$function$;

create or replace function public.admin_activate_user_device(
  p_user_id uuid,
  p_device_id text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.admin_activate_user_device(p_user_id, p_device_id);
$function$;

revoke all on function public.claim_user_device(text, text, text) from public, anon;
revoke all on function public.check_user_device(text, text, text) from public, anon;
revoke all on function public.admin_revoke_user_device(uuid, text) from public, anon;
revoke all on function public.admin_activate_user_device(uuid, text) from public, anon;
grant execute on function public.claim_user_device(text, text, text) to authenticated;
grant execute on function public.check_user_device(text, text, text) to authenticated;
grant execute on function public.admin_revoke_user_device(uuid, text) to authenticated;
grant execute on function public.admin_activate_user_device(uuid, text) to authenticated;

-- Preserve the existing approval/product-access semantics and add the device
-- requirement only to non-admin branches.
create or replace function private.can_current_user_access_mcq()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and (
        (p.role = 'admin'::public.app_user_role and p.approved is true)
        or (
          p.role = 'student'::public.app_user_role
          and p.approved is true
          and p.mcq_access_enabled is true
          and private.current_session_has_active_device()
        )
      )
  );
$function$;

create or replace function private.can_current_user_access_courses()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and (
        (p.role = 'admin'::public.app_user_role and p.approved is true)
        or (
          p.role = 'student'::public.app_user_role
          and p.courses_access_enabled is true
          and private.current_session_has_active_device()
        )
      )
  );
$function$;

create or replace function private.platform_suggestion_matches_current_profile(
  target_year integer,
  target_semester integer
)
returns boolean
language sql
security definer
set search_path = ''
as $function$
  select private.current_session_has_active_device()
    and exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'student'::public.app_user_role
        and p.courses_access_enabled is true
        and (
          (target_year is null and target_semester is null)
          or (target_year = p.academic_year and target_semester is null)
          or (target_year = p.academic_year and target_semester = p.academic_semester)
        )
    );
$function$;

create or replace function private.can_select_platform_course(
  target_course_id uuid,
  target_enrollment_mode text,
  target_is_active boolean,
  target_is_published boolean
)
returns boolean
language sql
security definer
set search_path = ''
as $function$
  select private.current_session_has_active_device()
    and not private.is_app_feature_enabled('courses_coming_soon')
    and exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'student'::public.app_user_role
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
$function$;

-- Defense in depth for all direct REST access. Existing policies remain
-- permissive and unchanged; this single restrictive policy must also pass.
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
    execute format(
      'create policy device_session_gate on public.%I as restrictive for all to authenticated using ((select private.current_session_has_active_device())) with check ((select private.current_session_has_active_device()))',
      target_table
    );
  end loop;
end;
$block$;

drop policy if exists device_session_gate on storage.objects;
create policy device_session_gate
on storage.objects
as restrictive
for all
to authenticated
using ((select private.current_session_has_active_device()))
with check ((select private.current_session_has_active_device()));

-- Anonymous fallback access to legacy app_state backups would otherwise let a
-- denied session omit its JWT and bypass the device gate.
drop policy if exists app_state_select_anon on public.app_state;
drop policy if exists app_state_insert_anon on public.app_state;
drop policy if exists app_state_update_anon on public.app_state;

-- Push-token RPCs are privileged definer paths and must enforce the same gate.
create or replace function private.register_push_token(
  p_token text,
  p_platform text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  caller_id uuid := auth.uid();
  clean_token text := btrim(coalesce(p_token, ''));
  clean_platform text := lower(btrim(coalesce(p_platform, '')));
  registered_id uuid;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if not private.current_session_has_active_device() then
    raise exception 'Active registered device required' using errcode = '42501';
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
$function$;

create or replace function private.unregister_push_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  deleted_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not private.current_session_has_active_device() then
    raise exception 'Active registered device required' using errcode = '42501';
  end if;

  delete from public.push_device_tokens
  where user_id = auth.uid()
    and token = btrim(coalesce(p_token, ''));
  get diagnostics deleted_count = row_count;
  return deleted_count > 0;
end;
$function$;

comment on table public.user_devices is
  'One registered installation per non-admin account, bound to the active Supabase Auth session.';
comment on function private.current_session_has_active_device() is
  'RLS helper: admins pass; non-admins require auth.uid() and JWT session_id to match the active user_devices row.';
comment on function public.claim_user_device(text, text, text) is
  'Claims the first installation or records a denied/revoked attempt. Used by Flutter and the static website.';
comment on function public.check_user_device(text, text, text) is
  'Rechecks that this installation and JWT session still own the active device slot.';

notify pgrst, 'reload schema';

commit;
