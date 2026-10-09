-- Admin layers, part 3: per-action permissions inside each area.
--
-- A super admin can now tick exactly what another admin may do ("Add new
-- users", "Edit questions", "Send notifications", ...), not just whole areas.
--
-- Additive and reversible: no existing policy or trigger is changed. The area
-- guards from 20260930030100 keep working as before; this adds a second,
-- finer check on top.
--
-- admin_permissions.permissions:
--   null  = every action in the admin's areas (how every existing row behaves,
--           so nobody loses anything when this runs).
--   array = only these actions. The website keeps `areas` equal to the areas
--           that have at least one ticked action.
-- Super admins can do everything whatever this column holds.
--
-- Enforcement is by triggers, not RLS policies, because the website saves
-- through upserts: an INSERT policy is checked even when the upsert ends up
-- updating, so RLS cannot tell "add" from "edit". Row triggers can: AFTER
-- INSERT fires only for rows really inserted, BEFORE UPDATE only for rows
-- really updated (and an update that changes nothing is let through).
-- Changes made by other triggers or FK cascades (pg_trigger_depth() > 1),
-- the service role and Edge Functions (auth.uid() is null), and non-admins are
-- never checked here. The four admin Edge Functions check their action
-- themselves.
--
-- Actions:
--   users.create, users.edit, users.access, users.password, users.delete,
--   users.organizations                                       (area people)
--   mcq.subjects, mcq.questions_create, mcq.questions_edit,
--   mcq.questions_delete, mcq.bulk_import                     (area mcq)
--   video_courses.manage                                      (area video_courses)
--   messaging.notifications, messaging.popups                 (area messaging)
--   system.view                                               (area system)
--
-- Rollback: supabase/rollbacks/20261009235000_admin_action_permissions_rollback.sql

alter table public.admin_permissions
  add column if not exists permissions text[];

alter table public.admin_permissions
  drop constraint if exists admin_permissions_permissions_ck;
alter table public.admin_permissions
  add constraint admin_permissions_permissions_ck
  check (
    permissions is null
    or permissions <@ array[
      'users.create', 'users.edit', 'users.access', 'users.password', 'users.delete', 'users.organizations',
      'mcq.subjects', 'mcq.questions_create', 'mcq.questions_edit', 'mcq.questions_delete', 'mcq.bulk_import',
      'video_courses.manage',
      'messaging.notifications', 'messaging.popups',
      'system.view'
    ]::text[]
  );

comment on column public.admin_permissions.permissions is
  'Admin layers: the actions this admin may take inside their areas. Null = every action in their areas.';

-- ---------------------------------------------------------------------------
-- Checks.
-- ---------------------------------------------------------------------------
create or replace function private.admin_permission_area(target_permission text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case split_part(target_permission, '.', 1)
    when 'users' then 'people'
    when 'mcq' then 'mcq'
    when 'video_courses' then 'video_courses'
    when 'messaging' then 'messaging'
    when 'system' then 'system'
    else null
  end;
$$;

create or replace function private.admin_can(target_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin_user()
    and exists (
      select 1
      from public.admin_permissions ap
      where ap.user_id = (select auth.uid())
        and (
          ap.is_super
          or (
            private.admin_permission_area(target_permission) = any (ap.areas)
            and (ap.permissions is null or target_permission = any (ap.permissions))
          )
        )
    );
$$;

revoke all on function private.admin_permission_area(text) from public;
revoke all on function private.admin_can(text) from public;
grant execute on function private.admin_permission_area(text) to authenticated, service_role;
grant execute on function private.admin_can(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Generic guard. Trigger arguments: the actions (comma separated, any one is
-- enough) needed to insert, to update and to delete a row. An empty argument
-- means that operation is not checked.
-- ---------------------------------------------------------------------------
create or replace function private.guard_admin_action()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  needed text;
  allowed boolean := false;
  action text;
begin
  if actor is null or pg_trigger_depth() > 1 or not private.is_admin_user() then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    needed := tg_argv[0];
  elsif tg_op = 'UPDATE' then
    if (to_jsonb(new) - 'updated_at') = (to_jsonb(old) - 'updated_at') then
      return new;
    end if;
    needed := tg_argv[1];
  else
    needed := tg_argv[2];
  end if;

  if coalesce(needed, '') = '' then
    return coalesce(new, old);
  end if;

  foreach action in array string_to_array(needed, ',')
  loop
    if private.admin_can(trim(action)) then
      allowed := true;
      exit;
    end if;
  end loop;

  if not allowed then
    raise exception 'Your admin account is not allowed to % % (needs %).',
      lower(tg_op), tg_table_name, needed
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

-- Profiles: approval and access switches are one action, everything else
-- about the account another. An admin's own row is never checked. Admin
-- accounts are already super-admin only (guard_admin_account_changes).
create or replace function private.guard_admin_profile_action()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  access_columns text[] := array[
    'approved', 'mcq_access_enabled', 'courses_access_enabled',
    'auto_approval_blocked_at', 'mcq_access_held_at'
  ];
  old_row jsonb;
  new_row jsonb;
begin
  if actor is null or pg_trigger_depth() > 1 or not private.is_admin_user() then
    return coalesce(new, old);
  end if;
  if coalesce(new.id, old.id) = actor then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    if not private.admin_can('users.create') then
      raise exception 'Your admin account is not allowed to add users.' using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if not private.admin_can('users.delete') then
      raise exception 'Your admin account is not allowed to remove users.' using errcode = '42501';
    end if;
    return old;
  end if;

  old_row := to_jsonb(old) - 'updated_at';
  new_row := to_jsonb(new) - 'updated_at';
  if (old_row - access_columns) is distinct from (new_row - access_columns)
     and not private.admin_can('users.edit') then
    raise exception 'Your admin account is not allowed to edit user details.' using errcode = '42501';
  end if;
  if exists (
       select 1 from unnest(access_columns) as c(name)
       where old_row -> c.name is distinct from new_row -> c.name
     )
     and not private.admin_can('users.access') then
    raise exception 'Your admin account is not allowed to approve users or change their access.' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- Questions: the website deletes a question by archiving it (status ->
-- 'archived'), so that update needs the delete action; any other change needs
-- the edit action (or bulk import, which re-imports existing questions).
create or replace function private.guard_admin_question_action()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  old_row jsonb;
  new_row jsonb;
begin
  if actor is null or pg_trigger_depth() > 1 or not private.is_admin_user() then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    if not (private.admin_can('mcq.questions_create') or private.admin_can('mcq.bulk_import')) then
      raise exception 'Your admin account is not allowed to add questions.' using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if not private.admin_can('mcq.questions_delete') then
      raise exception 'Your admin account is not allowed to delete questions.' using errcode = '42501';
    end if;
    return old;
  end if;

  old_row := to_jsonb(old) - 'updated_at' - 'status';
  new_row := to_jsonb(new) - 'updated_at' - 'status';
  if new.status::text = 'archived' and old.status::text is distinct from 'archived' then
    if not private.admin_can('mcq.questions_delete') then
      raise exception 'Your admin account is not allowed to delete questions.' using errcode = '42501';
    end if;
  elsif new.status is distinct from old.status then
    new_row := new_row || jsonb_build_object('status', new.status);
    old_row := old_row || jsonb_build_object('status', old.status);
  end if;
  if old_row is distinct from new_row
     and not (private.admin_can('mcq.questions_edit') or private.admin_can('mcq.bulk_import')) then
    raise exception 'Your admin account is not allowed to edit questions.' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_admin_action() from public;
revoke all on function private.guard_admin_profile_action() from public;
revoke all on function private.guard_admin_question_action() from public;

drop trigger if exists trg_questions_aa_admin_action_before on public.questions;
create trigger trg_questions_aa_admin_action_before
  before update or delete on public.questions
  for each row execute function private.guard_admin_question_action();
drop trigger if exists trg_questions_admin_action_after_insert on public.questions;
create trigger trg_questions_admin_action_after_insert
  after insert on public.questions
  for each row execute function private.guard_admin_question_action();

-- Profiles. The BEFORE UPDATE trigger is named so it runs before the other
-- BEFORE triggers (they fire alphabetically): it sees exactly what the
-- website sent, not what eligibility/auto-approval derive from it.
drop trigger if exists trg_profiles_aa_admin_action_before on public.profiles;
create trigger trg_profiles_aa_admin_action_before
  before update or delete on public.profiles
  for each row execute function private.guard_admin_profile_action();
drop trigger if exists trg_profiles_admin_action_after_insert on public.profiles;
create trigger trg_profiles_admin_action_after_insert
  after insert on public.profiles
  for each row execute function private.guard_admin_profile_action();

-- Every other guarded table: (table, insert actions, update actions, delete actions).
do $migration$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('question_choices', 'mcq.questions_create,mcq.questions_edit,mcq.bulk_import', 'mcq.questions_create,mcq.questions_edit,mcq.bulk_import', 'mcq.questions_create,mcq.questions_edit,mcq.bulk_import,mcq.questions_delete'),
      ('courses', 'mcq.subjects,mcq.bulk_import', 'mcq.subjects', 'mcq.subjects'),
      ('course_topics', 'mcq.subjects,mcq.bulk_import', 'mcq.subjects', 'mcq.subjects'),
      ('bulk_import_uploads', 'mcq.bulk_import', 'mcq.bulk_import', 'mcq.bulk_import'),
      ('notifications', 'messaging.notifications', 'messaging.notifications', 'messaging.notifications'),
      ('app_popups', 'messaging.popups', 'messaging.popups', 'messaging.popups'),
      ('universities', 'users.organizations', 'users.organizations', 'users.organizations'),
      ('organizations', 'users.organizations', 'users.organizations', 'users.organizations'),
      ('organization_codes', 'users.organizations', 'users.organizations', 'users.organizations'),
      ('organization_members', 'users.organizations', 'users.organizations', 'users.organizations')
    ) as t(table_name, insert_actions, update_actions, delete_actions)
  loop
    if to_regclass('public.' || spec.table_name) is null then
      raise notice 'Skipping missing table %', spec.table_name;
      continue;
    end if;
    execute format('drop trigger if exists %I on public.%I', 'trg_' || spec.table_name || '_aa_admin_action_before', spec.table_name);
    execute format(
      'create trigger %I before update or delete on public.%I for each row execute function private.guard_admin_action(%L, %L, %L)',
      'trg_' || spec.table_name || '_aa_admin_action_before', spec.table_name,
      spec.insert_actions, spec.update_actions, spec.delete_actions);
    execute format('drop trigger if exists %I on public.%I', 'trg_' || spec.table_name || '_admin_action_after_insert', spec.table_name);
    execute format(
      'create trigger %I after insert on public.%I for each row execute function private.guard_admin_action(%L, %L, %L)',
      'trg_' || spec.table_name || '_admin_action_after_insert', spec.table_name,
      spec.insert_actions, spec.update_actions, spec.delete_actions);
  end loop;
end;
$migration$;
