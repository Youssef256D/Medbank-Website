-- A creator always belongs to an organization, and a code of the wrong kind
-- says so instead of "doesn't match".
--
--   * `join_organization` answers WRONG_ROLE (with `code_role`) when the code
--     is real but for the other kind of account — a creator typing a student
--     code was told the code did not exist. It still counts as a wrong try.
--   * An account becomes a creator only while it is already a member of an
--     organization. Admin "Create account" (`admin-create-user`) adds the
--     memberships first and switches the role second; on the user page the
--     admin adds an organization before changing the role.
--   * A creator's last membership cannot be removed (add the new one first).
--     Deleting the account or the organization still cascades.
--   * A membership's role follows the account's role. It was copied once on
--     insert, so a student who became a creator stayed a "student" member and
--     could not limit courses to that organization.
--
-- Creators that already exist without an organization are left as they are;
-- they join with a creator code.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. A code of the other kind
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
  other_role text;
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

    -- A working code, but for the other kind of account.
    select c.role into other_role
    from public.organization_codes c
    join public.organizations o on o.id = c.organization_id
    where c.code = normalized
      and o.is_active
      and c.revoked_at is null
      and (c.expires_at is null or c.expires_at > now())
      and (c.max_uses is null or c.use_count < c.max_uses)
      and c.role <> profile_row.role::text;

    return jsonb_build_object(
      'ok', false,
      'code', case when other_role is null then 'INVALID_CODE' else 'WRONG_ROLE' end,
      'code_role', other_role,
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
-- 2. Becoming a creator needs an organization
-- ═══════════════════════════════════════════════════════════════════════

create or replace function private.guard_creator_has_organization()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.role::text = 'creator'
     and (tg_op = 'INSERT' or old.role::text is distinct from 'creator')
     and not exists (
       select 1 from public.organization_members om where om.user_id = new.id
     ) then
    raise exception 'A creator must belong to an organization. Add this account to an organization first.'
      using errcode = '23514', hint = 'CREATOR_NEEDS_ORGANIZATION';
  end if;
  return new;
end;
$function$;

revoke all on function private.guard_creator_has_organization() from public, anon, authenticated;

create trigger trg_profiles_creator_has_organization
  before insert or update of role on public.profiles
  for each row execute function private.guard_creator_has_organization();

-- A membership's role follows the account's.
create or replace function private.sync_member_role_from_profile()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  update public.organization_members
  set role = case when new.role::text = 'creator' then 'creator' else 'student' end
  where user_id = new.id;
  return null;
end;
$function$;

revoke all on function private.sync_member_role_from_profile() from public, anon, authenticated;

create trigger trg_profiles_sync_member_role
  after update of role on public.profiles
  for each row
  when (old.role is distinct from new.role)
  execute function private.sync_member_role_from_profile();

-- A creator keeps at least one organization.
create or replace function private.guard_creator_last_membership()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- An account or organization being deleted cascades here; let it.
  if exists (
       select 1 from public.profiles p
       where p.id = old.user_id and p.role::text = 'creator'
     )
     and exists (select 1 from public.organizations o where o.id = old.organization_id)
     and not exists (
       select 1 from public.organization_members om
       where om.user_id = old.user_id and om.organization_id <> old.organization_id
     ) then
    raise exception 'A creator must belong to an organization. Add them to another organization before removing this one.'
      using errcode = '23514', hint = 'CREATOR_NEEDS_ORGANIZATION';
  end if;
  return old;
end;
$function$;

revoke all on function private.guard_creator_last_membership() from public, anon, authenticated;

create trigger trg_organization_members_creator_last
  before delete on public.organization_members
  for each row execute function private.guard_creator_last_membership();

-- Existing memberships of accounts that are creators now.
update public.organization_members om
set role = 'creator'
from public.profiles p
where p.id = om.user_id and p.role::text = 'creator' and om.role <> 'creator';
