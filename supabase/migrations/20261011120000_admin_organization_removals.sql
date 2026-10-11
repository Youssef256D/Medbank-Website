-- Blocked members: the website lists who an admin removed from an
-- organization and can unblock them.
--
-- `private.organization_removals` (20261009210200) makes a removal stick: the
-- removed student's code for that organization answers REMOVED. The table is
-- private, so admins could not see or clear it. These two RPCs expose it to
-- admins holding `users.organizations`:
--   * admin_list_organization_removals(org) — blocked accounts, newest first.
--   * admin_clear_organization_removal(org, user) — unblock: the student's
--     code works again. Adding them back as a member also clears it (the
--     existing after-insert trigger).
-- Rollback: supabase/rollbacks/20261011120000_admin_organization_removals.sql

create or replace function public.admin_list_organization_removals(p_organization_id uuid)
returns table (
  user_id uuid,
  full_name text,
  email text,
  public_user_id bigint,
  role text,
  removed_at timestamptz,
  removed_by uuid,
  removed_by_name text
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not private.admin_can('users.organizations') then
    raise exception 'Your admin account cannot manage organizations.'
      using errcode = '42501';
  end if;

  return query
  select r.user_id,
         p.full_name,
         p.email,
         p.public_user_id,
         p.role::text,
         r.removed_at,
         r.removed_by,
         coalesce(nullif(btrim(a.full_name), ''), a.email)
  from private.organization_removals r
  join public.profiles p on p.id = r.user_id
  left join public.profiles a on a.id = r.removed_by
  where r.organization_id = p_organization_id
  order by r.removed_at desc;
end;
$function$;

create or replace function public.admin_clear_organization_removal(p_organization_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  cleared integer;
begin
  if not private.admin_can('users.organizations') then
    raise exception 'Your admin account cannot manage organizations.'
      using errcode = '42501';
  end if;

  delete from private.organization_removals r
  where r.organization_id = p_organization_id and r.user_id = p_user_id;
  get diagnostics cleared = row_count;
  return cleared > 0;
end;
$function$;

revoke all on function public.admin_list_organization_removals(uuid) from public, anon;
revoke all on function public.admin_clear_organization_removal(uuid, uuid) from public, anon;
grant execute on function public.admin_list_organization_removals(uuid) to authenticated;
grant execute on function public.admin_clear_organization_removal(uuid, uuid) to authenticated;
