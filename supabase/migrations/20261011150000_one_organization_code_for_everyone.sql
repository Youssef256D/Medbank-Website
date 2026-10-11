-- One organization code for students and creators.
--
-- A code used to be for one kind of account (`organization_codes.role`), so an
-- organization needed a student code and a separate creator code, and a
-- creator typing the student code was told WRONG_ROLE. Now any code of an
-- active organization works for both: the account's own role decides the
-- membership's role (the existing `organization_members` trigger already sets
-- it from `profiles.role`), so a creator who joins by code is a creator member
-- and a student a student member.
--
--   * `join_organization_as` no longer filters on the code's role and never
--     answers WRONG_ROLE. Everything else is unchanged: five wrong tries an
--     hour, REMOVED for a member an admin took out, ALREADY_MEMBER, limits,
--     expiry and revocation.
--   * `organization_codes.role` stays (older app builds still read and send
--     it) but means nothing any more. New codes store 'student'.
--
-- Rollback: re-run section 1 of 20261009233100_creator_needs_organization.sql.

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

comment on column public.organization_codes.role is
  'Unused since 20261011150000: every code works for students and creators alike. Kept for older app builds.';
comment on table public.organization_codes is
  'Join codes. One code works for students and creators; the account''s role decides the membership''s role.';
