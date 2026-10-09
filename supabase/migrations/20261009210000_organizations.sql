-- Organizations: who a student belongs to decides which video courses they see.
--
--   * A video course is either public (everyone) or limited to one or more
--     organizations (`platform_courses.visibility`,
--     `platform_course_organizations`).
--   * A student joins by typing an organization code. The code is checked
--     here, in `private.join_organization_as`, and nowhere else: the app and
--     the website only send what was typed. Five wrong codes in an hour lock
--     the form for that hour.
--   * Creators belong to the organizations an admin adds them to, and may
--     limit their courses only to those.
--   * The MCQ Bank is not part of this. University, college, academic year and
--     semester keep deciding who gets which MCQ subjects.
--
-- This migration only adds. Nothing reads the new tables until
-- 20261009210100_video_course_audience repoints the access rules, and every
-- course starts public, so nobody loses anything here.
--
-- Data: the one university becomes an organization with the same id and a
-- fresh student code, and every student who named it becomes a member.
-- `public.universities` stays: the MCQ Bank still reads it.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. Tables
-- ═══════════════════════════════════════════════════════════════════════

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) >= 2),
  name_ar text,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.organizations is
  'A university, faculty or centre. Members see its organization-only video courses. Hidden (is_active = false) organizations accept no new codes.';

create unique index organizations_name_lower_uniq
  on public.organizations (lower(btrim(name)));

create trigger trg_organizations_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

-- Codes are stored upper case, because admins read and share them. The check
-- keeps every stored code upper case, so comparing against upper(btrim(input))
-- is an exact match.
create table public.organization_codes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z0-9-]{6,40}$'),
  role text not null default 'student' check (role in ('student', 'creator')),
  label text check (label is null or length(label) <= 120),
  expires_at timestamptz,
  max_uses integer check (max_uses is null or max_uses > 0),
  use_count integer not null default 0 check (use_count >= 0),
  revoked_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table public.organization_codes is
  'Join codes. role = student or creator; a code only works for an account of that role.';

create index organization_codes_org_idx on public.organization_codes (organization_id);
create index organization_codes_created_by_idx on public.organization_codes (created_by);

create table public.organization_members (
  organization_id uuid not null references public.organizations (id) on delete restrict,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'student' check (role in ('student', 'creator')),
  source text not null default 'admin' check (source in ('code', 'admin', 'migration')),
  code_id uuid references public.organization_codes (id) on delete set null,
  added_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);
comment on table public.organization_members is
  'Who belongs where. Deleting a row removes the member and every organization-only video course with them.';

create index organization_members_user_idx on public.organization_members (user_id);
create index organization_members_code_idx on public.organization_members (code_id);
create index organization_members_added_by_idx on public.organization_members (added_by);

create table public.platform_course_organizations (
  course_id uuid not null references public.platform_courses (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (course_id, organization_id)
);
comment on table public.platform_course_organizations is
  'The organizations an organization-only video course is shown to. Ignored while the course is public.';

create index platform_course_organizations_org_idx
  on public.platform_course_organizations (organization_id);

alter table public.platform_courses
  add column visibility text not null default 'public'
    check (visibility in ('public', 'organization'));
comment on column public.platform_courses.visibility is
  'public: every student. organization: members of the organizations in platform_course_organizations only.';

alter table public.profiles
  add column organization_joined_at timestamptz;
comment on column public.profiles.organization_joined_at is
  'When this account first joined an organization. Informational.';

-- Failed and successful code attempts, for the hourly limit. No client reads it.
create table private.organization_code_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  succeeded boolean not null,
  attempted_at timestamptz not null default now()
);
create index organization_code_attempts_user_time_idx
  on private.organization_code_attempts (user_id, attempted_at desc);

-- ═══════════════════════════════════════════════════════════════════════
-- 2. Who sees a video course: the one check
-- ═══════════════════════════════════════════════════════════════════════

create or replace function private.user_in_video_course_audience(p_user_id uuid, p_course_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.platform_courses c
    where c.id = p_course_id
      and (
        c.visibility = 'public'
        or (
          p_user_id is not null
          and exists (
            select 1
            from public.platform_course_organizations co
            join public.organization_members om
              on om.organization_id = co.organization_id
            where co.course_id = c.id
              and om.user_id = p_user_id
          )
        )
      )
  );
$function$;

create or replace function private.video_course_audience_allows(p_course_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select private.user_in_video_course_audience((select auth.uid()), p_course_id);
$function$;

-- For the Edge Functions that sign video URLs and tokens: they run with the
-- service role, which bypasses RLS, so they have to ask explicitly. Granted to
-- service_role only.
create or replace function public.user_in_video_course_audience(p_user_id uuid, p_course_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select private.user_in_video_course_audience(p_user_id, p_course_id);
$function$;

create or replace function private.is_organization_member(p_organization_id uuid, p_role text default null)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.organization_members om
    where om.organization_id = p_organization_id
      and om.user_id = (select auth.uid())
      and (p_role is null or om.role = p_role)
  );
$function$;

revoke all on function private.user_in_video_course_audience(uuid, uuid) from public, anon;
revoke all on function private.video_course_audience_allows(uuid) from public;
revoke all on function public.user_in_video_course_audience(uuid, uuid) from public, anon, authenticated;
revoke all on function private.is_organization_member(uuid, text) from public, anon;
grant execute on function private.user_in_video_course_audience(uuid, uuid) to authenticated;
grant execute on function private.video_course_audience_allows(uuid) to anon, authenticated;
grant execute on function public.user_in_video_course_audience(uuid, uuid) to service_role;
grant execute on function private.is_organization_member(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 3. Joining
-- ═══════════════════════════════════════════════════════════════════════

-- Eight characters from an alphabet without look-alikes (no O/0, I/1/L).
create or replace function private.generate_organization_code()
returns text
language plpgsql
volatile security definer
set search_path to ''
as $function$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea;
  result text;
begin
  loop
    bytes := extensions.gen_random_bytes(8);
    result := '';
    for i in 0..7 loop
      result := result || substr(alphabet, (get_byte(bytes, i) % length(alphabet)) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.organization_codes c where c.code = result);
  end loop;
  return result;
end;
$function$;

revoke all on function private.generate_organization_code() from public, anon, authenticated;

-- A membership takes its role from the account, and an admin-added one
-- records who added it.
create or replace function private.organization_member_before_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  profile_role text;
begin
  select p.role::text into profile_role from public.profiles p where p.id = new.user_id;
  new.role := case when profile_role = 'creator' then 'creator' else 'student' end;
  if new.source = 'admin' then
    new.added_by := coalesce(new.added_by, (select auth.uid()));
  end if;
  return new;
end;
$function$;

create or replace function private.organization_member_after_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  update public.profiles
  set organization_joined_at = coalesce(organization_joined_at, now())
  where id = new.user_id;
  return null;
end;
$function$;

revoke all on function private.organization_member_before_insert() from public, anon, authenticated;
revoke all on function private.organization_member_after_insert() from public, anon, authenticated;

create trigger trg_organization_members_before_insert
  before insert on public.organization_members
  for each row execute function private.organization_member_before_insert();

create trigger trg_organization_members_after_insert
  after insert on public.organization_members
  for each row execute function private.organization_member_after_insert();

-- The one place a code is checked. Returns a result object rather than
-- raising, so a wrong code still records its attempt.
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
    and c.role = profile_row.role::text
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

create or replace function public.join_organization(p_code text)
returns jsonb
language sql
volatile security definer
set search_path to ''
as $function$
  select private.join_organization_as((select auth.uid()), p_code);
$function$;

revoke all on function public.join_organization(text) from public, anon;
grant execute on function public.join_organization(text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. Admin tools
-- ═══════════════════════════════════════════════════════════════════════

-- Creates a code: a generated one, or the admin's own (upper-cased).
create or replace function public.admin_create_organization_code(
  p_organization_id uuid,
  p_role text default 'student',
  p_label text default null,
  p_expires_at timestamptz default null,
  p_max_uses integer default null,
  p_code text default null
)
returns public.organization_codes
language plpgsql
security definer
set search_path to ''
as $function$
declare
  chosen text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  created public.organization_codes;
begin
  if not private.admin_has_area('people') then
    raise exception 'Your admin account does not include the People area.'
      using errcode = '42501';
  end if;
  if chosen is not null and chosen !~ '^[A-Z0-9-]{6,40}$' then
    raise exception 'A code is 6 to 40 letters, digits or dashes.' using errcode = '22023';
  end if;

  insert into public.organization_codes
    (organization_id, code, role, label, expires_at, max_uses, created_by)
  values (
    p_organization_id,
    coalesce(chosen, private.generate_organization_code()),
    coalesce(p_role, 'student'),
    nullif(btrim(coalesce(p_label, '')), ''),
    p_expires_at,
    p_max_uses,
    (select auth.uid())
  )
  returning * into created;

  return created;
end;
$function$;

revoke all on function public.admin_create_organization_code(uuid, text, text, timestamptz, integer, text) from public, anon;
grant execute on function public.admin_create_organization_code(uuid, text, text, timestamptz, integer, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 5. Row level security
-- ═══════════════════════════════════════════════════════════════════════

alter table public.organizations enable row level security;
alter table public.organization_codes enable row level security;
alter table public.organization_members enable row level security;
alter table public.platform_course_organizations enable row level security;

-- Organizations are not listed publicly: a student or creator sees only their own.
create policy organizations_select on public.organizations
  for select to authenticated
  using ((select private.is_admin_user()) or private.is_organization_member(id));
create policy organizations_admin_write on public.organizations
  for all to authenticated
  using ((select private.admin_has_area('people')))
  with check ((select private.admin_has_area('people')));

create policy organization_codes_admin_select on public.organization_codes
  for select to authenticated
  using ((select private.is_admin_user()));
create policy organization_codes_admin_write on public.organization_codes
  for all to authenticated
  using ((select private.admin_has_area('people')))
  with check ((select private.admin_has_area('people')));

create policy organization_members_select on public.organization_members
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin_user()));
create policy organization_members_admin_write on public.organization_members
  for all to authenticated
  using ((select private.admin_has_area('people')))
  with check ((select private.admin_has_area('people')) and source = 'admin');

create policy platform_course_organizations_select on public.platform_course_organizations
  for select to authenticated
  using (
    (select private.is_admin_user())
    or private.owns_platform_course(course_id)
    or private.is_organization_member(organization_id)
  );
create policy platform_course_organizations_admin_write on public.platform_course_organizations
  for all to authenticated
  using ((select private.admin_has_area('video_courses')))
  with check ((select private.admin_has_area('video_courses')));
-- A creator limits their own course only to organizations an admin made them
-- a creator member of.
create policy platform_course_organizations_creator_insert on public.platform_course_organizations
  for insert to authenticated
  with check (
    private.owns_platform_course(course_id)
    and private.is_organization_member(organization_id, 'creator')
  );
create policy platform_course_organizations_creator_delete on public.platform_course_organizations
  for delete to authenticated
  using (private.owns_platform_course(course_id));

revoke all on public.organizations, public.organization_codes,
  public.organization_members, public.platform_course_organizations from anon;
grant select, insert, update, delete on public.organizations,
  public.organization_codes, public.organization_members to authenticated;
grant select, insert, delete on public.platform_course_organizations to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 6. Universities become organizations
-- ═══════════════════════════════════════════════════════════════════════

insert into public.organizations (id, name, name_ar, is_active, sort_order, created_at)
select u.id, u.name, u.name_ar, u.is_active, u.sort_order, u.created_at
from public.universities u
on conflict (id) do nothing;

insert into public.organization_codes (organization_id, code, role, label)
select o.id, private.generate_organization_code(), 'student', 'Created from the university list'
from public.organizations o
where not exists (select 1 from public.organization_codes c where c.organization_id = o.id);

insert into public.organization_members (organization_id, user_id, source)
select p.university_id, p.id, 'migration'
from public.profiles p
where p.university_id is not null
  and p.role = 'student'
on conflict do nothing;
