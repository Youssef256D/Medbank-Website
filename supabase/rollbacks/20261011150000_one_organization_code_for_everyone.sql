-- Rollback for 20261011150000_one_organization_code_for_everyone:
-- restores the role-checked join (codes for students OR creators, WRONG_ROLE).

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

comment on column public.organization_codes.role is null;
comment on table public.organization_codes is
  'Join codes. role = student or creator; a code only works for an account of that role.';
