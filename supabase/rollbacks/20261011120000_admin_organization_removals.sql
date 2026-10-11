-- Rollback for 20261011120000_admin_organization_removals.
drop function if exists public.admin_clear_organization_removal(uuid, uuid);
drop function if exists public.admin_list_organization_removals(uuid);
