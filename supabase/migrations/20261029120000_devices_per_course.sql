-- Several devices per student, and each paid video course on one device.
--
-- Until now an account had exactly one device (user_devices' primary key was
-- user_id). Now:
--
--   * There is no device limit unless an admin sets one. A limit can be set
--     for everyone, for a university, for an organization, or for one
--     student. A university or organization can also follow the global
--     setting or turn the limit off for its students. A student's own
--     setting is the final word; otherwise, when their university and
--     organizations disagree, the strictest wins.
--   * A paid video course (coupon or admin-given) works only on the device it
--     is bound to (course_device_bindings). A coupon binds the course to the
--     device that redeemed it; a second full-course coupon on another device
--     adds that device. Only an admin moves a course between devices.
--   * The app sends its install id in the `x-medbank-device` header. Every
--     paid-access check reads it, so the lesson rules, resources and the
--     course list all follow the device. Free previews are not bound.
--   * Older builds send no header. They can never register more than one
--     device, whatever the limit, so they keep working exactly as before.
--     While "allow older builds" is on, a request without the header is
--     treated as coming from the student's device when they have exactly
--     one; with two, it gets no paid content.
--
-- The device id is a random per-install id, never a hardware id, and no
-- student-facing function returns one.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

create table public.device_access_settings (
  id boolean primary key default true check (id),
  limit_enabled boolean not null default false,
  device_limit integer not null default 2 check (device_limit between 1 and 10),
  allow_older_builds boolean not null default true,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table public.device_access_settings is
  'One row. How many app devices a student may use (when limit_enabled), and whether requests from builds that send no device header still reach paid content.';

-- No limit until an admin sets one. Older builds stay at one device anyway
-- (user_device_gate), so this changes nothing for them.
insert into public.device_access_settings (id) values (true);

alter table public.device_access_settings enable row level security;
revoke all on public.device_access_settings from anon, authenticated;
grant select, update on public.device_access_settings to authenticated;

create policy "Admins read device settings"
  on public.device_access_settings for select to authenticated
  using ((select private.is_admin_user()));

create policy "People admins change device settings"
  on public.device_access_settings for update to authenticated
  using ((select private.admin_has_area('people')))
  with check ((select private.admin_has_area('people')));

create or replace function private.stamp_device_access_settings()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end;
$$;

create trigger trg_device_access_settings_stamp
  before update on public.device_access_settings
  for each row execute function private.stamp_device_access_settings();

-- Universities and organizations: follow the global setting, turn the
-- limit off for their students, or set their own number.
alter table public.organizations
  add column device_limit_mode text not null default 'inherit'
    check (device_limit_mode in ('inherit', 'off', 'custom')),
  add column device_limit integer check (device_limit between 1 and 10),
  add constraint organizations_device_limit_matches_mode
    check ((device_limit_mode = 'custom') = (device_limit is not null));

comment on column public.organizations.device_limit_mode is
  'inherit = the global device setting; off = no device limit for its students; custom = device_limit. The strictest of a student''s university and organizations wins.';

alter table public.universities
  add column device_limit_mode text not null default 'inherit'
    check (device_limit_mode in ('inherit', 'off', 'custom')),
  add column device_limit integer check (device_limit between 1 and 10),
  add constraint universities_device_limit_matches_mode
    check ((device_limit_mode = 'custom') = (device_limit is not null));

comment on column public.universities.device_limit_mode is
  'inherit = the global device setting; off = no device limit for its students; custom = device_limit. The strictest of a student''s university and organizations wins.';

-- One student's own limit, set by an admin. It beats every other setting,
-- in either direction. No row = follow the university and organizations.
create table public.user_device_limits (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  device_limit_mode text not null check (device_limit_mode in ('off', 'custom')),
  device_limit integer check (device_limit between 1 and 10),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint user_device_limits_matches_mode
    check ((device_limit_mode = 'custom') = (device_limit is not null))
);

comment on table public.user_device_limits is
  'An admin''s device limit for one student: off = no limit, custom = device_limit. Beats the global, university and organization settings.';

alter table public.user_device_limits enable row level security;
revoke all on public.user_device_limits from anon, authenticated;
grant select, insert, update, delete on public.user_device_limits to authenticated;

create policy "Admins read student device limits"
  on public.user_device_limits for select to authenticated
  using ((select private.is_admin_user()));

create policy "People admins set student device limits"
  on public.user_device_limits for all to authenticated
  using ((select private.admin_has_area('people')))
  with check ((select private.admin_has_area('people')));

create trigger trg_user_device_limits_stamp
  before insert or update on public.user_device_limits
  for each row execute function private.stamp_device_access_settings();

-- The device limit a student has right now. Null means no limit.
create or replace function private.effective_device_limit(p_user uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  with global_limit as (
    select case when s.limit_enabled then s.device_limit end as lim
    from public.device_access_settings s
    where s.id
  ),
  own as (
    select case u.device_limit_mode when 'off' then null else u.device_limit end as lim
    from public.user_device_limits u
    where u.user_id = p_user
  ),
  scope_limits as (
    select o.device_limit_mode as mode, o.device_limit as lim
    from public.organization_members m
    join public.organizations o on o.id = m.organization_id
    where m.user_id = p_user
      and o.is_active is true
    union all
    select un.device_limit_mode, un.device_limit
    from public.profiles p
    join public.universities un on un.id = p.university_id
    where p.id = p_user
  ),
  resolved as (
    select case mode
      when 'inherit' then (select lim from global_limit)
      when 'off' then null
      else lim
    end as lim
    from scope_limits
  )
  select case
    when exists (select 1 from own) then (select lim from own)
    when exists (select 1 from resolved) then (select min(lim) from resolved)
    else (select lim from global_limit)
  end;
$$;

revoke all on function private.effective_device_limit(uuid) from public;

-- ---------------------------------------------------------------------------
-- Devices: several rows per account
-- ---------------------------------------------------------------------------

alter table public.user_devices drop constraint user_devices_pkey;
alter table public.user_devices add primary key (user_id, device_id);

comment on table public.user_devices is
  'The app installations each student account may use, up to private.effective_device_limit. Written only by claim_user_device; admins read and delete (delete = release the device).';

-- ---------------------------------------------------------------------------
-- Which device each paid course is on
-- ---------------------------------------------------------------------------

create table public.course_device_bindings (
  user_id uuid not null references public.profiles (id) on delete cascade,
  course_id uuid not null references public.platform_courses (id) on delete cascade,
  device_id text not null check (char_length(device_id) between 8 and 128),
  source text not null
    check (source in ('coupon', 'admin', 'first_device', 'backfill', 'moved')),
  source_coupon_id uuid references public.platform_course_coupons (id) on delete set null,
  bound_by uuid references public.profiles (id) on delete set null,
  bound_at timestamptz not null default now(),
  primary key (user_id, course_id, device_id)
);

comment on table public.course_device_bindings is
  'The devices a student''s paid video course plays on. Kept when a device is released, so the same install gets it back; an admin moves it to another device instead.';

create index course_device_bindings_device_idx
  on public.course_device_bindings (user_id, device_id);

alter table public.course_device_bindings enable row level security;
revoke all on public.course_device_bindings from anon, authenticated;
grant select, delete on public.course_device_bindings to authenticated;

-- Students never read this table: it holds device ids. get_my_course_devices
-- tells them what they need.
create policy "Admins read course devices"
  on public.course_device_bindings for select to authenticated
  using ((select private.is_admin_user()));

create policy "People admins remove course devices"
  on public.course_device_bindings for delete to authenticated
  using ((select private.admin_has_area('people')));

-- The admin log watches both new tables like the rest.
create trigger log_admin_insert after insert on public.course_device_bindings
  referencing new table as new_rows for each statement
  execute function private.log_admin_table_write();
create trigger log_admin_update after update on public.course_device_bindings
  referencing old table as old_rows new table as new_rows for each statement
  execute function private.log_admin_table_write();
create trigger log_admin_delete after delete on public.course_device_bindings
  referencing old table as old_rows for each statement
  execute function private.log_admin_table_write();
create trigger log_admin_insert after insert on public.user_device_limits
  referencing new table as new_rows for each statement
  execute function private.log_admin_table_write();
create trigger log_admin_update after update on public.user_device_limits
  referencing old table as old_rows new table as new_rows for each statement
  execute function private.log_admin_table_write();
create trigger log_admin_delete after delete on public.user_device_limits
  referencing old table as old_rows for each statement
  execute function private.log_admin_table_write();
create trigger log_admin_update after update on public.device_access_settings
  referencing old table as old_rows new table as new_rows for each statement
  execute function private.log_admin_table_write();

-- The install id the app sent with this request, if any.
create or replace function private.request_device_id()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(btrim(coalesce(
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-medbank-device',
    ''
  )), '');
$$;

-- Whether p_user may open paid content of p_course from p_device (null = the
-- request sent no device header). The device must still be registered: a
-- released device loses its courses at once.
create or replace function private.course_device_allows(
  p_user uuid,
  p_course uuid,
  p_device text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_user is null then false
    when exists (
      select 1 from public.profiles p
      where p.id = p_user and p.role in ('admin', 'creator')
    ) then true
    -- An admin-exempted account is not device-limited at all.
    when exists (
      select 1 from public.user_device_exemptions x where x.user_id = p_user
    ) then true
    when p_device is not null then exists (
      select 1
      from public.course_device_bindings b
      join public.user_devices d
        on d.user_id = b.user_id and d.device_id = b.device_id
      where b.user_id = p_user
        and b.course_id = p_course
        and b.device_id = p_device
    )
    -- An older build: allowed only when there is no doubt which device it is.
    else coalesce(
      (select s.allow_older_builds from public.device_access_settings s where s.id),
      false
    )
      and (select count(*) from public.user_devices d where d.user_id = p_user) = 1
      and exists (
        select 1
        from public.course_device_bindings b
        join public.user_devices d
          on d.user_id = b.user_id and d.device_id = b.device_id
        where b.user_id = p_user and b.course_id = p_course
      )
  end;
$$;

revoke all on function private.course_device_allows(uuid, uuid, text) from public;

create or replace function private.current_course_device_allows(p_course uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.course_device_allows(
    (select auth.uid()), p_course, private.request_device_id()
  );
$$;

revoke all on function private.current_course_device_allows(uuid) from public;

-- The device a request without a header most likely came from: the only one,
-- or the one seen last. Used only to bind a coupon an older build redeemed.
create or replace function private.likely_request_device(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    private.request_device_id(),
    (select d.device_id from public.user_devices d
      where d.user_id = p_user
      order by d.last_seen_at desc
      limit 1)
  );
$$;

revoke all on function private.likely_request_device(uuid) from public;

-- Courses the student owns that are on no device yet go to this one: a
-- course given before they had the app, or bought on the website.
create or replace function private.bind_unbound_courses(p_user uuid, p_device text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.course_device_bindings (user_id, course_id, device_id, source)
  select p_user, owned.course_id, p_device, 'first_device'
  from (
    select e.course_id from public.platform_course_enrollments e where e.user_id = p_user
    union
    select me.course_id from public.platform_course_module_entitlements me where me.user_id = p_user
  ) owned
  where not exists (
    select 1 from public.course_device_bindings b
    where b.user_id = p_user and b.course_id = owned.course_id
  )
  on conflict do nothing;
$$;

revoke all on function private.bind_unbound_courses(uuid, text) from public;

-- An admin-given course goes straight to the student's device when they
-- have exactly one. With two, the admin picks (admin_bind_course_device); a
-- course nobody picked for goes to the next device that opens the app.
create or replace function private.bind_new_access_to_only_device()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device text;
begin
  -- Coupons bind themselves, to the device that redeemed them.
  -- (Nested: PL/pgSQL may read a field the other table lacks before `and`
  -- decides.)
  if tg_table_name = 'platform_course_enrollments' then
    if new.access_source = 'coupon' then
      return null;
    end if;
  elsif new.grant_source = 'coupon' then
    return null;
  end if;
  if exists (
    select 1 from public.course_device_bindings b
    where b.user_id = new.user_id and b.course_id = new.course_id
  ) then
    return null;
  end if;
  if (select count(*) from public.user_devices d where d.user_id = new.user_id) = 1 then
    select d.device_id into v_device from public.user_devices d where d.user_id = new.user_id;
    insert into public.course_device_bindings
      (user_id, course_id, device_id, source, bound_by)
    values (new.user_id, new.course_id, v_device, 'admin', (select auth.uid()))
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create trigger trg_enrollment_bind_device
  after insert on public.platform_course_enrollments
  for each row execute function private.bind_new_access_to_only_device();

create trigger trg_module_entitlement_bind_device
  after insert on public.platform_course_module_entitlements
  for each row execute function private.bind_new_access_to_only_device();

-- ---------------------------------------------------------------------------
-- The device gate
-- ---------------------------------------------------------------------------

create or replace function private.user_device_gate(
  p_device_id text,
  p_device_name text,
  p_platform text,
  p_claim boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.app_user_role;
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_name text := left(btrim(coalesce(p_device_name, '')), 120);
  v_platform text := left(btrim(coalesce(p_platform, '')), 32);
  v_mine public.user_devices%rowtype;
  v_other public.user_devices%rowtype;
  v_limit integer;
  v_used integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if char_length(v_device_id) not between 8 and 128 then
    raise exception 'invalid_device_id' using errcode = '22023';
  end if;

  select p.role into v_role from public.profiles p where p.id = v_uid;
  if v_role in ('admin', 'creator') then
    return jsonb_build_object('status', 'allowed', 'devices_used', 0, 'device_limit', null);
  end if;

  -- Admin-granted exemption: same answer as for admins and creators. Nothing
  -- is claimed, and rows registered before the exemption are left alone.
  if exists (select 1 from public.user_device_exemptions e where e.user_id = v_uid) then
    return jsonb_build_object('status', 'allowed', 'devices_used', 0, 'device_limit', null);
  end if;

  v_limit := private.effective_device_limit(v_uid);
  -- A build that sends no device header cannot tell its courses apart from
  -- another device's, so it stays at one device whatever the limit.
  if private.request_device_id() is null then
    v_limit := least(coalesce(v_limit, 1), 1);
  end if;

  select * into v_mine
  from public.user_devices d
  where d.user_id = v_uid and d.device_id = v_device_id;

  if not found then
    if not p_claim then
      -- Checking never registers: this device was released since the app
      -- last claimed it.
      select count(*) into v_used from public.user_devices d where d.user_id = v_uid;
      return jsonb_build_object('status', 'revoked', 'devices_used', v_used, 'device_limit', v_limit);
    end if;

    -- One claim at a time per account, so two phones cannot both take the
    -- last free place.
    perform pg_advisory_xact_lock(hashtextextended('user_devices:' || v_uid::text, 0));
    select count(*) into v_used from public.user_devices d where d.user_id = v_uid;

    if v_limit is not null and v_used >= v_limit then
      select * into v_other
      from public.user_devices d
      where d.user_id = v_uid
      order by d.last_seen_at desc
      limit 1;
      return jsonb_build_object(
        'status', 'another_device_active',
        'active_device_name', nullif(v_other.device_name, ''),
        'active_device_platform', nullif(v_other.platform, ''),
        'registered_at', v_other.registered_at,
        'devices_used', v_used,
        'device_limit', v_limit
      );
    end if;

    insert into public.user_devices (user_id, device_id, device_name, platform)
    values (v_uid, v_device_id, v_name, v_platform)
    on conflict (user_id, device_id) do nothing;
    perform private.bind_unbound_courses(v_uid, v_device_id);
    return jsonb_build_object('status', 'allowed', 'devices_used', v_used + 1, 'device_limit', v_limit);
  end if;

  -- A registered device stays allowed even when the limit was lowered under
  -- it: a stricter rule only blocks new devices.
  if v_mine.last_seen_at < now() - interval '5 minutes'
     or (v_name <> '' and v_mine.device_name is distinct from v_name) then
    update public.user_devices
       set last_seen_at = now(),
           device_name = case when v_name <> '' then v_name else device_name end,
           platform = case when v_platform <> '' then v_platform else platform end
     where user_id = v_uid and device_id = v_device_id;
  end if;
  if p_claim then
    perform private.bind_unbound_courses(v_uid, v_device_id);
  end if;
  select count(*) into v_used from public.user_devices d where d.user_id = v_uid;
  return jsonb_build_object('status', 'allowed', 'devices_used', v_used, 'device_limit', v_limit);
end;
$$;

revoke all on function private.user_device_gate(text, text, text, boolean) from public;

-- ---------------------------------------------------------------------------
-- Paid access follows the device
-- ---------------------------------------------------------------------------

create or replace function private.can_access_platform_lesson(target_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
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
          or (
            (
              exists (
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
            and private.current_course_device_allows(l.course_id)
          )
        )
    )
    and private.platform_lesson_sequence_open(target_lesson_id);
$$;

create or replace function private.has_any_platform_course_access(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
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
    )
    and private.current_course_device_allows(target_course_id);
$$;

create or replace function private.has_full_platform_course_access(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and private.video_course_audience_allows(target_course_id)
    and exists (
      select 1
      from public.platform_course_enrollments e
      where e.user_id = (select auth.uid())
        and e.course_id = target_course_id
        and e.access_scope = 'full'
    )
    and private.current_course_device_allows(target_course_id);
$$;

create or replace function private.has_platform_course_access(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
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
    )
    and private.current_course_device_allows(target_course_id);
$$;

create or replace function private.has_platform_module_access(target_module_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
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
        and private.current_course_device_allows(m.course_id)
    );
$$;

create or replace function private.student_owns_platform_module(target_module_id uuid)
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
      and private.video_course_audience_allows(m.course_id)
      and private.current_course_device_allows(m.course_id)
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
$$;

-- Only the courses on this device. Courses on another device come from
-- get_my_course_devices, so the app can say where they are.
create or replace function public.get_my_platform_course_access()
returns table(course_id uuid, access_scope text, access_source text, module_ids uuid[])
language sql
stable
security definer
set search_path = ''
as $$
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
    and private.current_course_device_allows(ac.course_id)
  group by ac.course_id;
$$;

-- Every course the student owns, and whether it plays on this device. For a
-- course on another device, the names of the devices it is on (never ids).
create or replace function public.get_my_course_devices()
returns table(course_id uuid, on_this_device boolean, device_names text[])
language sql
stable
security definer
set search_path = ''
as $$
  with owned as (
    select e.course_id
    from public.platform_course_enrollments e
    where e.user_id = (select auth.uid())
    union
    select me.course_id
    from public.platform_course_module_entitlements me
    where me.user_id = (select auth.uid())
  )
  select
    o.course_id,
    private.current_course_device_allows(o.course_id),
    coalesce((
      select array_agg(coalesce(nullif(d.device_name, ''), d.platform) order by b.bound_at)
      from public.course_device_bindings b
      join public.user_devices d
        on d.user_id = b.user_id and d.device_id = b.device_id
      where b.user_id = (select auth.uid()) and b.course_id = o.course_id
    ), '{}'::text[])
  from owned o
  where (select auth.uid()) is not null
    and private.video_course_audience_allows(o.course_id);
$$;

revoke all on function public.get_my_course_devices() from public, anon;
grant execute on function public.get_my_course_devices() to authenticated;

-- For the Edge Functions that sign video URLs: they run as the service role,
-- which bypasses RLS, so they ask this explicitly with the header they got.
create or replace function public.course_device_allows_for(
  p_user uuid,
  p_course uuid,
  p_device text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.course_device_allows(p_user, p_course, nullif(btrim(coalesce(p_device, '')), ''));
$$;

revoke all on function public.course_device_allows_for(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.course_device_allows_for(uuid, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Coupons bind to the device that redeemed them
-- ---------------------------------------------------------------------------

create or replace function public.redeem_platform_course_coupon(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  v_device text;
  device_exempt boolean := false;
  bound_here boolean := false;
  bound_elsewhere boolean := false;
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

    -- The device this coupon is for. A header naming a device the account
    -- does not have is refused; no header at all (an older build, or the
    -- website) means the device seen last, or none yet.
    device_exempt := exists (
      select 1 from public.user_device_exemptions x where x.user_id = actor_id
    );
    v_device := private.request_device_id();
    if v_device is not null and not device_exempt and not exists (
      select 1 from public.user_devices d
      where d.user_id = actor_id and d.device_id = v_device
    ) then
      return jsonb_build_object('ok', false, 'code', 'DEVICE_NOT_REGISTERED');
    end if;
    if v_device is null then
      v_device := private.likely_request_device(actor_id);
    end if;

    select
      coalesce(bool_or(b.device_id = v_device), false),
      coalesce(bool_or(b.device_id <> v_device), false) or (v_device is null and count(*) > 0)
    into bound_here, bound_elsewhere
    from public.course_device_bindings b
    where b.user_id = actor_id and b.course_id = coupon_row.course_id;

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
      -- A course is bound to devices as a whole, so a module coupon cannot
      -- add a second device: that would open every module the student owns
      -- there. A second device needs a full-course coupon.
      if bound_elsewhere and not bound_here and not device_exempt then
        return jsonb_build_object('ok', false, 'code', 'COURSE_ON_OTHER_DEVICE');
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
      -- A full course already on this device needs no second coupon. On
      -- another device it is a purchase for this one.
      if already_full and (bound_here or device_exempt or (v_device is null and not bound_elsewhere)) then
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

    if v_device is not null then
      insert into public.course_device_bindings
        (user_id, course_id, device_id, source, source_coupon_id)
      values (actor_id, coupon_row.course_id, v_device, 'coupon', coupon_row.id)
      on conflict do nothing;
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
$$;

-- ---------------------------------------------------------------------------
-- Admin: see and move a student's courses between devices
-- ---------------------------------------------------------------------------

-- Every course the student owns, with the devices it is on. A course on no
-- device yet comes back once with a null device_id, for the admin to place.
create or replace function public.admin_list_course_devices(p_user uuid)
returns table(
  course_id uuid,
  course_name text,
  device_id text,
  device_name text,
  platform text,
  device_registered boolean,
  source text,
  bound_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with owned as (
    select e.course_id from public.platform_course_enrollments e where e.user_id = p_user
    union
    select me.course_id from public.platform_course_module_entitlements me where me.user_id = p_user
  ),
  placed as (
    select b.course_id, b.device_id, b.source, b.bound_at
    from public.course_device_bindings b
    where b.user_id = p_user
  )
  select
    c.id,
    c.course_name,
    p.device_id,
    d.device_name,
    d.platform,
    d.device_id is not null,
    p.source,
    p.bound_at
  from (
    select o.course_id, pl.device_id, pl.source, pl.bound_at
    from owned o
    left join placed pl on pl.course_id = o.course_id
    union
    -- A binding outlives a revoked enrollment; still worth seeing.
    select pl.course_id, pl.device_id, pl.source, pl.bound_at from placed pl
  ) p
  join public.platform_courses c on c.id = p.course_id
  left join public.user_devices d
    on d.user_id = p_user and d.device_id = p.device_id
  where (select private.is_admin_user())
  order by c.course_name, p.bound_at nulls first;
$$;

revoke all on function public.admin_list_course_devices(uuid) from public, anon;
grant execute on function public.admin_list_course_devices(uuid) to authenticated;

-- The device limit that applies to this student now (null = no limit).
create or replace function public.admin_get_device_limit(p_user uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case when (select private.is_admin_user())
    then private.effective_device_limit(p_user) end;
$$;

revoke all on function public.admin_get_device_limit(uuid) from public, anon;
grant execute on function public.admin_get_device_limit(uuid) to authenticated;

-- Puts a course the student owns on one of their devices. With p_replace it
-- comes off every other device (a move); without, the device is added.
create or replace function public.admin_bind_course_device(
  p_user uuid,
  p_course uuid,
  p_device text,
  p_replace boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (select private.admin_has_area('people')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.user_devices d
    where d.user_id = p_user and d.device_id = p_device
  ) then
    raise exception 'device_not_registered' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.platform_course_enrollments e
    where e.user_id = p_user and e.course_id = p_course
  ) and not exists (
    select 1 from public.platform_course_module_entitlements me
    where me.user_id = p_user and me.course_id = p_course
  ) then
    raise exception 'course_not_owned' using errcode = '22023';
  end if;

  if p_replace then
    delete from public.course_device_bindings b
    where b.user_id = p_user and b.course_id = p_course and b.device_id <> p_device;
  end if;
  insert into public.course_device_bindings (user_id, course_id, device_id, source, bound_by)
  values (p_user, p_course, p_device, 'admin', (select auth.uid()))
  on conflict do nothing;
end;
$$;

revoke all on function public.admin_bind_course_device(uuid, uuid, text, boolean) from public, anon;
grant execute on function public.admin_bind_course_device(uuid, uuid, text, boolean) to authenticated;

-- Moves every course on one device (registered or already released) to
-- another registered device. Returns how many courses moved.
create or replace function public.admin_move_device_courses(
  p_user uuid,
  p_from_device text,
  p_to_device text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moved integer;
begin
  if not (select private.admin_has_area('people')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.user_devices d
    where d.user_id = p_user and d.device_id = p_to_device
  ) then
    raise exception 'device_not_registered' using errcode = '22023';
  end if;
  if p_from_device = p_to_device then
    return 0;
  end if;

  insert into public.course_device_bindings (user_id, course_id, device_id, source, bound_by)
  select b.user_id, b.course_id, p_to_device, 'moved', (select auth.uid())
  from public.course_device_bindings b
  where b.user_id = p_user and b.device_id = p_from_device
  on conflict do nothing;

  delete from public.course_device_bindings b
  where b.user_id = p_user and b.device_id = p_from_device;
  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

revoke all on function public.admin_move_device_courses(uuid, text, text) from public, anon;
grant execute on function public.admin_move_device_courses(uuid, text, text) to authenticated;

-- How many students have more registered devices than their limit allows,
-- for the confirmation before an admin lowers it. They keep those devices.
create or replace function public.admin_count_students_over_device_limit(
  p_limit integer
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case when (select private.is_admin_user()) then (
    select count(*)::integer
    from (
      select d.user_id
      from public.user_devices d
      group by d.user_id
      having count(*) > p_limit
    ) over_limit
  ) end;
$$;

revoke all on function public.admin_count_students_over_device_limit(integer) from public, anon;
grant execute on function public.admin_count_students_over_device_limit(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Backfill: every course a student owns today goes on their one device.
-- ---------------------------------------------------------------------------

insert into public.course_device_bindings (user_id, course_id, device_id, source)
select owned.user_id, owned.course_id, d.device_id, 'backfill'
from (
  select e.user_id, e.course_id from public.platform_course_enrollments e
  union
  select me.user_id, me.course_id from public.platform_course_module_entitlements me
) owned
join public.user_devices d on d.user_id = owned.user_id
on conflict do nothing;
