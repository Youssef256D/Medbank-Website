-- Admin layers, part 1: who is a super admin, and which areas each admin may
-- change. Enforcement is part 2 (20260930030100_admin_area_enforcement.sql);
-- this migration changes no existing policy.
--
-- Areas: people (Users, Universities), mcq (MCQ Bank), video_courses,
-- messaging (Notifications, Pop-ups), system (Activity, Logs). Super admins
-- have every area plus the super-only powers: managing admins and their
-- areas, Site Access, and Hermes.
--
-- An admin with no row here has no areas. Every admin that exists when this
-- runs is seeded as a super admin, so nobody loses access.

create table if not exists public.admin_permissions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  is_super boolean not null default false,
  areas text[] not null default '{}'::text[],
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,
  constraint admin_permissions_areas_ck
    check (areas <@ array['people', 'mcq', 'video_courses', 'messaging', 'system']::text[])
);

comment on table public.admin_permissions is
  'Admin layers: is_super grants everything; otherwise areas lists what the admin may change. Missing row = no areas.';

alter table public.admin_permissions enable row level security;
revoke all on public.admin_permissions from anon;
grant select, insert, update, delete on public.admin_permissions to authenticated;

-- ---------------------------------------------------------------------------
-- Checks used by policies, functions and the website.
-- ---------------------------------------------------------------------------
create or replace function private.is_super_admin()
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
        and ap.is_super
    );
$$;

create or replace function private.admin_has_area(target_area text)
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
        and (ap.is_super or target_area = any (ap.areas))
    );
$$;

-- True for everyone who is not an admin (their rights are decided by the
-- existing policies), and for admins who hold the area. Used by the
-- restrictive policies in part 2 so students and creators are unaffected.
create or replace function private.admin_write_allowed(target_area text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not private.is_admin_user() or private.admin_has_area(target_area);
$$;

create or replace function private.admin_super_allowed()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not private.is_admin_user() or private.is_super_admin();
$$;

revoke all on function private.is_super_admin() from public;
revoke all on function private.admin_has_area(text) from public;
revoke all on function private.admin_write_allowed(text) from public;
revoke all on function private.admin_super_allowed() from public;
grant execute on function private.is_super_admin() to authenticated, service_role;
grant execute on function private.admin_has_area(text) to authenticated, service_role;
grant execute on function private.admin_write_allowed(text) to authenticated, service_role;
grant execute on function private.admin_super_allowed() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- admin_permissions: an admin reads their own row; super admins read and
-- write every row.
-- ---------------------------------------------------------------------------
drop policy if exists admin_permissions_select on public.admin_permissions;
create policy admin_permissions_select
  on public.admin_permissions for select
  to authenticated
  using (user_id = (select auth.uid()) or (select private.is_super_admin()));

drop policy if exists admin_permissions_insert_super on public.admin_permissions;
create policy admin_permissions_insert_super
  on public.admin_permissions for insert
  to authenticated
  with check ((select private.is_super_admin()));

drop policy if exists admin_permissions_update_super on public.admin_permissions;
create policy admin_permissions_update_super
  on public.admin_permissions for update
  to authenticated
  using ((select private.is_super_admin()))
  with check ((select private.is_super_admin()));

drop policy if exists admin_permissions_delete_super on public.admin_permissions;
create policy admin_permissions_delete_super
  on public.admin_permissions for delete
  to authenticated
  using ((select private.is_super_admin()));

-- Stamp who changed a row, and never let the last super admin disappear.
create or replace function private.admin_permissions_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.is_super
     and (tg_op = 'DELETE' or not new.is_super)
     and not exists (
       select 1
       from public.admin_permissions ap
       join public.profiles p on p.id = ap.user_id
       where ap.is_super
         and ap.user_id <> old.user_id
         and p.role::text = 'admin'
         and p.approved is true
     ) then
    raise exception 'At least one super admin must remain.' using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  new.updated_at := now();
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  return new;
end;
$$;

drop trigger if exists trg_admin_permissions_before_write on public.admin_permissions;
create trigger trg_admin_permissions_before_write
  before insert or update or delete on public.admin_permissions
  for each row
  execute function private.admin_permissions_before_write();

-- ---------------------------------------------------------------------------
-- Admin accounts themselves are super-admin territory. A limited admin with
-- the People area manages students and creators, but cannot create, promote,
-- demote, edit, suspend or delete an admin account, and cannot change their
-- own role. Backend jobs and the service role (auth.uid() is null) and super
-- admins pass through; students and creators are already limited by RLS.
-- ---------------------------------------------------------------------------
create or replace function private.guard_admin_account_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
begin
  -- Demoting or deleting the last super admin would lock everyone out.
  if tg_op in ('UPDATE', 'DELETE')
     and old.role::text = 'admin'
     and (tg_op = 'DELETE' or new.role::text <> 'admin' or new.approved is not true)
     and exists (select 1 from public.admin_permissions ap where ap.user_id = old.id and ap.is_super)
     and not exists (
       select 1
       from public.admin_permissions ap
       join public.profiles p on p.id = ap.user_id
       where ap.is_super
         and ap.user_id <> old.id
         and p.role::text = 'admin'
         and p.approved is true
     ) then
    raise exception 'At least one super admin must remain.' using errcode = '42501';
  end if;

  if actor is null or not private.is_admin_user() or private.is_super_admin() then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    if new.role::text = 'admin' then
      raise exception 'Only a super admin can create an admin account.' using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.role::text = 'admin' then
      raise exception 'Only a super admin can delete an admin account.' using errcode = '42501';
    end if;
    return old;
  end if;

  if new.role is distinct from old.role
     and (old.role::text = 'admin' or new.role::text = 'admin') then
    raise exception 'Only a super admin can grant or remove the admin role.' using errcode = '42501';
  end if;
  if old.role::text = 'admin' and old.id <> actor then
    raise exception 'Only a super admin can change another admin account.' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_guard_admin_accounts on public.profiles;
create trigger trg_profiles_guard_admin_accounts
  before insert or update or delete on public.profiles
  for each row
  execute function private.guard_admin_account_changes();

-- ---------------------------------------------------------------------------
-- Seed: every current admin becomes a super admin.
-- ---------------------------------------------------------------------------
insert into public.admin_permissions (user_id, is_super, areas)
select p.id, true, array['people', 'mcq', 'video_courses', 'messaging', 'system']::text[]
from public.profiles p
where p.role::text = 'admin'
on conflict (user_id) do nothing;
