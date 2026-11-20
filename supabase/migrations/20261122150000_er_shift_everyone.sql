-- ER Shift for everyone: one admin switch that opens ER Shift to every
-- account, whatever its college, stage, organization or approval.
--
-- The switch is a row in public.app_feature_flags (`er_shift_everyone`),
-- so it shows up with the other switches on the app's Admin → Site access
-- and is written under the same RLS: admins only, and an admin limited to
-- some areas needs the "people" area (the restrictive guard already maps
-- every key but courses_coming_soon to 'people').
--
-- private.can_play_er_shift is the single gate — RLS on cases and runs,
-- the profile RPC, run submission and daily results all call it — so this
-- adds one more way in and touches nothing else. Off (the default) leaves
-- the rules exactly as they were.

insert into public.app_feature_flags (feature_key, enabled, description)
values (
  'er_shift_everyone',
  false,
  'When on, every account can play ER Shift, whatever its college, stage or organization.'
)
on conflict (feature_key) do nothing;

create or replace function private.can_play_er_shift(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select p_user_id is not null and (
    exists (
      select 1 from public.profiles p
      where p.id = p_user_id and p.role = 'admin'
    )
    or (
      exists (
        select 1 from public.app_feature_flags f
        where f.feature_key = 'er_shift_everyone' and f.enabled
      )
      and exists (select 1 from public.profiles p where p.id = p_user_id)
    )
    or exists (
      select 1
      from public.organization_members om
      join public.organizations o on o.id = om.organization_id
      where om.user_id = p_user_id
        and o.er_shift_enabled
        and o.is_active
    )
    or exists (
      select 1 from public.profiles p
      where p.id = p_user_id
        and p.role = 'student'
        and p.approved
        and p.college = 'medicine'
        and p.training_stage is not null
    )
  );
$$;

revoke all on function private.can_play_er_shift(uuid) from public, anon;
grant execute on function private.can_play_er_shift(uuid) to authenticated;
