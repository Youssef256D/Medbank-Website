-- Organization codes are optional, and a student may add more than one.
--
--   * A student without an organization is a normal account: public video
--     courses, and pop-ups meant for everyone or for "students without an
--     organization". Approval never waited for one in MedBank.
--   * A student types a code whenever they like, as many times as they have
--     codes (sign-up, the join pop-up, Profile → Add an organization code).
--     The hourly limit of five wrong codes still applies.
--   * Removing a member takes every course of that organization away. So that
--     removal sticks, the same student cannot type that organization's code
--     again (`private.organization_removals`); an admin adding them back
--     clears it.
--   * Pop-ups gain an organization audience (everyone, students without an
--     organization, or the members of one organization) on top of the role
--     and academic-year audience, and a pop-up that links to a video course
--     reaches only students who can open that course.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. Removals stick
-- ═══════════════════════════════════════════════════════════════════════

create table private.organization_removals (
  organization_id uuid not null,
  user_id uuid not null,
  removed_at timestamptz not null default now(),
  removed_by uuid,
  primary key (organization_id, user_id)
);
comment on table private.organization_removals is
  'Students an admin removed from an organization. Their code for that organization stops working for them until an admin adds them back.';

create or replace function private.organization_member_after_delete()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- An organization or account being deleted cascades here too; only a
  -- membership removed while both still exist is a removal.
  if exists (select 1 from public.organizations o where o.id = old.organization_id)
     and exists (select 1 from public.profiles p where p.id = old.user_id) then
    insert into private.organization_removals (organization_id, user_id, removed_by)
    values (old.organization_id, old.user_id, (select auth.uid()))
    on conflict (organization_id, user_id) do update
      set removed_at = now(), removed_by = excluded.removed_by;
  end if;
  return null;
end;
$function$;

revoke all on function private.organization_member_after_delete() from public, anon, authenticated;

create trigger trg_organization_members_after_delete
  after delete on public.organization_members
  for each row execute function private.organization_member_after_delete();

-- Re-adding a member (by an admin) clears the removal.
create or replace function private.organization_member_after_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  update public.profiles
  set organization_joined_at = coalesce(organization_joined_at, now())
  where id = new.user_id;

  delete from private.organization_removals r
  where r.organization_id = new.organization_id and r.user_id = new.user_id;

  return null;
end;
$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 2. Joining: any number of codes, removals answer REMOVED
-- ═══════════════════════════════════════════════════════════════════════

create or replace function private.join_organization_as(p_user_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  normalized text := upper(btrim(coalesce(p_code, '')));
  profile_row public.profiles%rowtype;
  code_row public.organization_codes%rowtype;
  failed_recently integer;
  org_name text;
  org_name_ar text;
  attempts_limit constant integer := 5;
begin
  if p_user_id is null then
    return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
  end if;

  select * into profile_row from public.profiles p where p.id = p_user_id;
  if not found or profile_row.role::text not in ('student', 'creator') then
    return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
  end if;

  select count(*) into failed_recently
  from private.organization_code_attempts a
  where a.user_id = p_user_id
    and not a.succeeded
    and a.attempted_at > now() - interval '1 hour';

  if failed_recently >= attempts_limit then
    return jsonb_build_object('ok', false, 'code', 'TOO_MANY_ATTEMPTS');
  end if;

  select c.* into code_row
  from public.organization_codes c
  join public.organizations o on o.id = c.organization_id
  where c.code = normalized
    and o.is_active
    and c.revoked_at is null
    and (c.expires_at is null or c.expires_at > now())
    and (c.max_uses is null or c.use_count < c.max_uses)
    and c.role = profile_row.role::text
  for update of c;

  if not found then
    insert into private.organization_code_attempts (user_id, succeeded)
    values (p_user_id, false);
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_CODE',
      'attempts_left', greatest(attempts_limit - failed_recently - 1, 0)
    );
  end if;

  select o.name, o.name_ar into org_name, org_name_ar
  from public.organizations o where o.id = code_row.organization_id;

  if exists (
    select 1 from public.organization_members om
    where om.organization_id = code_row.organization_id and om.user_id = p_user_id
  ) then
    return jsonb_build_object(
      'ok', true, 'code', 'ALREADY_MEMBER',
      'organization_id', code_row.organization_id,
      'organization_name', org_name, 'organization_name_ar', org_name_ar
    );
  end if;

  if exists (
    select 1 from private.organization_removals r
    where r.organization_id = code_row.organization_id and r.user_id = p_user_id
  ) then
    return jsonb_build_object('ok', false, 'code', 'REMOVED');
  end if;

  insert into public.organization_members (organization_id, user_id, source, code_id)
  values (code_row.organization_id, p_user_id, 'code', code_row.id);

  update public.organization_codes
  set use_count = use_count + 1
  where id = code_row.id;

  insert into private.organization_code_attempts (user_id, succeeded)
  values (p_user_id, true);

  return jsonb_build_object(
    'ok', true, 'code', 'SUCCESS',
    'organization_id', code_row.organization_id,
    'organization_name', org_name, 'organization_name_ar', org_name_ar
  );
end;
$function$;

revoke all on function private.join_organization_as(uuid, text) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 3. Pop-ups: an organization audience, and a join target
-- ═══════════════════════════════════════════════════════════════════════

alter table public.app_popups
  add column organization_audience text not null default 'everyone'
    check (organization_audience in ('everyone', 'no_organization', 'organization')),
  add column target_organization_id uuid
    references public.organizations(id) on delete set null;

-- An organization is named only for the 'organization' audience. When that
-- organization is deleted the pop-up keeps its audience and reaches nobody,
-- rather than widening to everyone.
alter table public.app_popups
  add constraint app_popups_target_organization_pairing
    check (target_organization_id is null or organization_audience = 'organization');

create index app_popups_target_organization_idx
  on public.app_popups (target_organization_id);

comment on column public.app_popups.organization_audience is
  'everyone; no_organization: accounts in no organization; organization: members of target_organization_id.';

alter table public.app_popups drop constraint app_popups_target_route_check;
alter table public.app_popups add constraint app_popups_target_route_check
  check (target_route = any (array[
    'app-launcher', 'dashboard', 'create-test', 'analytics', 'video-courses',
    'profile', 'notifications', 'join-organization'
  ]));

CREATE OR REPLACE FUNCTION public.get_my_active_popups()
 RETURNS SETOF public.app_popups
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select p.*
  from public.app_popups p
  left join public.app_popup_views v
    on v.popup_id = p.id and v.user_id = auth.uid()
  cross join lateral (
    select
      role,
      academic_year,
      exists (
        select 1 from public.organization_members om where om.user_id = auth.uid()
      ) as in_any_organization
    from public.profiles
    where id = auth.uid()
  ) me
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at is null or p.ends_at > now())
    -- profiles.role is the app_user_role enum, not text, so the cast is
    -- load-bearing: without it Postgres refuses the comparison outright
    -- (42883) and the whole function fails to create.
    and (p.audience_role = 'all' or p.audience_role = me.role::text)
    and (
      p.audience_academic_year is null
      or p.audience_academic_year = me.academic_year
    )
    and (
      case p.organization_audience
        when 'everyone' then true
        when 'no_organization' then not me.in_any_organization
        when 'organization' then
          p.target_organization_id is not null
          and exists (
            select 1 from public.organization_members om
            where om.user_id = auth.uid()
              and om.organization_id = p.target_organization_id
          )
        else false
      end
    )
    -- A pop-up about a video course reaches only students who can open it.
    -- CASE, so a malformed id is never cast.
    and (
      case
        when p.target_video_course_id is null then true
        when p.target_video_course_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then private.user_in_video_course_audience(auth.uid(), p.target_video_course_id::uuid)
        else false
      end
    )
    and (
      case p.display_rule
        when 'every_launch' then true
        when 'daily' then
          v.last_seen_at is null
          or v.last_seen_at < date_trunc('day', now())
        else v.seen_count is null or v.seen_count = 0
      end
    )
  order by p.priority desc, p.created_at desc;
$function$;
