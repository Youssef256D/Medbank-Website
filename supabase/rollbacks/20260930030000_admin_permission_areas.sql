-- Rollback for 20260930030000_admin_permission_areas.sql.
-- Roll back 20260930030100_admin_area_enforcement.sql first.

drop trigger if exists trg_profiles_guard_admin_accounts on public.profiles;
drop function if exists private.guard_admin_account_changes();
drop trigger if exists trg_admin_permissions_before_write on public.admin_permissions;
drop function if exists private.admin_permissions_before_write();
drop table if exists public.admin_permissions;
drop function if exists private.admin_super_allowed();
drop function if exists private.admin_write_allowed(text);
drop function if exists private.admin_has_area(text);
drop function if exists private.is_super_admin();
