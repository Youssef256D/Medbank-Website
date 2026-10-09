-- Rollback for 20261009235000_admin_action_permissions.sql.
-- Drops the per-action triggers and functions. The permissions column is kept
-- (dropping it would lose what super admins ticked); uncomment to remove it.

do $rollback$
declare
  table_name text;
begin
  foreach table_name in array array[
    'question_choices', 'courses', 'course_topics', 'bulk_import_uploads',
    'notifications', 'app_popups', 'universities', 'organizations', 'organization_codes',
    'organization_members'
  ]
  loop
    if to_regclass('public.' || table_name) is not null then
      execute format('drop trigger if exists %I on public.%I', 'trg_' || table_name || '_aa_admin_action_before', table_name);
      execute format('drop trigger if exists %I on public.%I', 'trg_' || table_name || '_admin_action_after_insert', table_name);
    end if;
  end loop;
end;
$rollback$;

drop trigger if exists trg_profiles_aa_admin_action_before on public.profiles;
drop trigger if exists trg_profiles_admin_action_after_insert on public.profiles;
drop trigger if exists trg_questions_aa_admin_action_before on public.questions;
drop trigger if exists trg_questions_admin_action_after_insert on public.questions;
drop function if exists private.guard_admin_question_action();
drop function if exists private.guard_admin_profile_action();
drop function if exists private.guard_admin_action();
drop function if exists private.admin_can(text);
drop function if exists private.admin_permission_area(text);
-- alter table public.admin_permissions drop constraint if exists admin_permissions_permissions_ck;
-- alter table public.admin_permissions drop column if exists permissions;
