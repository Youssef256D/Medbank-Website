begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Stable numeric public user IDs. Auth UUIDs remain the canonical internal key.
-- ---------------------------------------------------------------------------

create sequence if not exists public.profiles_public_user_id_seq
  as bigint
  start with 10000001
  increment by 1
  minvalue 10000001
  no maxvalue
  cache 32;

alter table public.profiles
  add column if not exists public_user_id bigint;

alter table public.profiles
  alter column public_user_id set default nextval('public.profiles_public_user_id_seq'::regclass);

update public.profiles
set public_user_id = nextval('public.profiles_public_user_id_seq'::regclass)
where public_user_id is null;

select setval(
  'public.profiles_public_user_id_seq'::regclass,
  greatest(coalesce((select max(public_user_id) from public.profiles), 10000000), 10000000),
  true
);

alter sequence public.profiles_public_user_id_seq
  owned by public.profiles.public_user_id;

alter table public.profiles
  alter column public_user_id drop default;

create or replace function private.assign_profile_public_user_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Always overwrite caller input. This avoids granting sequence access to
  -- browser roles and prevents clients choosing their own public identifier.
  new.public_user_id := nextval('public.profiles_public_user_id_seq'::regclass);
  return new;
end;
$$;

revoke all on function private.assign_profile_public_user_id() from public, anon, authenticated;

drop trigger if exists trg_profiles_assign_public_user_id on public.profiles;
create trigger trg_profiles_assign_public_user_id
before insert on public.profiles
for each row
execute function private.assign_profile_public_user_id();

alter table public.profiles
  alter column public_user_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_public_user_id_key'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_public_user_id_key unique (public_user_id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_public_user_id_positive_ck'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_public_user_id_positive_ck
      check (public_user_id >= 10000001) not valid;
  end if;
end
$$;

alter table public.profiles
  validate constraint profiles_public_user_id_positive_ck;

create or replace function private.protect_profile_public_user_id()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.public_user_id is not null
     and new.public_user_id is distinct from old.public_user_id then
    raise exception using
      errcode = '23514',
      message = 'public_user_id is immutable';
  end if;
  return new;
end;
$$;

revoke all on function private.protect_profile_public_user_id() from public, anon, authenticated;

drop trigger if exists trg_profiles_protect_public_user_id on public.profiles;
create trigger trg_profiles_protect_public_user_id
before update of public_user_id on public.profiles
for each row
execute function private.protect_profile_public_user_id();

create or replace function public.admin_find_profile_by_public_user_id(p_public_user_id bigint)
returns table (
  id uuid,
  public_user_id bigint,
  full_name text,
  email text,
  phone text,
  role public.app_user_role,
  approved boolean,
  academic_year smallint,
  academic_semester smallint,
  courses_access_enabled boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not (select private.is_admin_user()) then
    raise exception using errcode = '42501', message = 'UNAUTHORIZED';
  end if;

  return query
  select
    p.id,
    p.public_user_id,
    p.full_name,
    p.email,
    p.phone,
    p.role,
    p.approved,
    p.academic_year,
    p.academic_semester,
    p.courses_access_enabled
  from public.profiles p
  where p.public_user_id = p_public_user_id;
end;
$$;

revoke all on function public.admin_find_profile_by_public_user_id(bigint) from public, anon;
grant execute on function public.admin_find_profile_by_public_user_id(bigint) to authenticated, service_role;

comment on column public.profiles.public_user_id is
  'Immutable numeric MedBank identifier for display/admin lookup. auth.users.id remains canonical.';

-- ---------------------------------------------------------------------------
-- Normalized YouTube lesson sources. Arbitrary administrator HTML is never used.
-- ---------------------------------------------------------------------------

alter table public.platform_course_lessons
  add column if not exists youtube_video_id varchar(11),
  add column if not exists video_original_url text;

create or replace function public.normalize_youtube_video_id(source text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  raw_value text := btrim(coalesce(source, ''));
  extracted text;
begin
  if raw_value ~ '^[A-Za-z0-9_-]{11}$' then
    return raw_value;
  end if;

  if raw_value !~* '^https?://([a-z0-9-]+\.)?(youtube\.com|youtu\.be|youtube-nocookie\.com)/' then
    return null;
  end if;

  extracted := substring(
    raw_value
    from '(?:[?&]v=|youtu\.be/|/embed/|/shorts/|/live/)([A-Za-z0-9_-]{11})(?:[^A-Za-z0-9_-]|$)'
  );

  if extracted ~ '^[A-Za-z0-9_-]{11}$' then
    return extracted;
  end if;
  return null;
end;
$$;

create or replace function public.youtube_privacy_embed_url(video_id text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when public.normalize_youtube_video_id(video_id) is null then null
    else 'https://www.youtube-nocookie.com/embed/'
      || public.normalize_youtube_video_id(video_id)
      || '?rel=0&modestbranding=1'
  end;
$$;

revoke all on function public.normalize_youtube_video_id(text) from public, anon;
revoke all on function public.youtube_privacy_embed_url(text) from public, anon;
grant execute on function public.normalize_youtube_video_id(text) to authenticated, service_role;
grant execute on function public.youtube_privacy_embed_url(text) to authenticated, service_role;

create or replace function private.normalize_platform_lesson_video_source()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  candidate text;
  normalized_id text;
begin
  candidate := coalesce(
    nullif(btrim(new.youtube_video_id), ''),
    nullif(btrim(new.video_original_url), ''),
    nullif(btrim(new.video_url), '')
  );
  normalized_id := public.normalize_youtube_video_id(candidate);

  if lower(coalesce(btrim(new.video_provider), '')) = 'youtube'
     or new.youtube_video_id is not null
     or new.video_original_url is not null
     or normalized_id is not null then
    if normalized_id is null then
      raise exception using errcode = '23514', message = 'INVALID_YOUTUBE_URL';
    end if;
    new.video_provider := 'youtube';
    new.youtube_video_id := normalized_id;
    new.video_original_url := coalesce(
      nullif(btrim(new.video_original_url), ''),
      nullif(btrim(new.video_url), ''),
      'https://www.youtube.com/watch?v=' || normalized_id
    );
    new.video_url := null;
  else
    new.youtube_video_id := null;
    new.video_original_url := null;
    if coalesce(btrim(new.video_url), '') = '' then
      new.video_url := null;
      new.video_provider := null;
    elsif new.video_url like 'supabase-storage://%' then
      new.video_provider := 'supabase_storage';
    elsif new.video_url like 'cloudflare-stream://%'
       or new.video_url ~* '(cloudflarestream\.com|videodelivery\.net)/' then
      new.video_provider := 'cloudflare_stream';
    else
      new.video_provider := coalesce(nullif(lower(btrim(new.video_provider)), ''), 'external');
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.normalize_platform_lesson_video_source() from public, anon, authenticated;

drop trigger if exists trg_platform_lessons_normalize_video_source on public.platform_course_lessons;
create trigger trg_platform_lessons_normalize_video_source
before insert or update of video_url, video_provider, youtube_video_id, video_original_url
on public.platform_course_lessons
for each row
execute function private.normalize_platform_lesson_video_source();

update public.platform_course_lessons
set
  video_provider = case
    when video_url like 'supabase-storage://%' then 'supabase_storage'
    when video_url like 'cloudflare-stream://%'
      or video_url ~* '(cloudflarestream\.com|videodelivery\.net)/' then 'cloudflare_stream'
    when coalesce(btrim(video_url), '') <> '' then 'external'
    else null
  end
where youtube_video_id is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'platform_course_lessons_youtube_source_ck'
      and conrelid = 'public.platform_course_lessons'::regclass
  ) then
    alter table public.platform_course_lessons
      add constraint platform_course_lessons_youtube_source_ck
      check (
        (
          video_provider = 'youtube'
          and youtube_video_id ~ '^[A-Za-z0-9_-]{11}$'
          and coalesce(btrim(video_original_url), '') <> ''
          and video_url is null
        )
        or (
          coalesce(video_provider, '') <> 'youtube'
          and youtube_video_id is null
          and video_original_url is null
        )
      ) not valid;
  end if;
end
$$;

alter table public.platform_course_lessons
  validate constraint platform_course_lessons_youtube_source_ck;

comment on column public.platform_course_lessons.youtube_video_id is
  'Validated normalized 11-character YouTube ID. Used to build youtube-nocookie embeds.';
comment on column public.platform_course_lessons.video_original_url is
  'Original administrator-entered YouTube URL for audit/editing. Never rendered as HTML.';

-- ---------------------------------------------------------------------------
-- Coupon, entitlement, redemption, and access-source data model.
-- ---------------------------------------------------------------------------

create table if not exists public.platform_course_coupons (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.platform_courses(id) on delete restrict,
  code_hash bytea not null,
  code_preview varchar(4) not null,
  coupon_type text not null,
  is_enabled boolean not null default true,
  expires_at timestamptz,
  batch_name text,
  note text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  redeemed_by uuid references public.profiles(id) on delete restrict,
  redeemed_at timestamptz,
  disabled_by uuid references public.profiles(id) on delete restrict,
  disabled_at timestamptz,
  constraint platform_course_coupons_code_hash_key unique (code_hash),
  constraint platform_course_coupons_type_ck check (coupon_type in ('full_course', 'module_access')),
  constraint platform_course_coupons_preview_ck check (code_preview ~ '^[A-F2-9]{4}$'),
  constraint platform_course_coupons_redeemed_ck check (
    (redeemed_by is null and redeemed_at is null)
    or (redeemed_by is not null and redeemed_at is not null)
  ),
  constraint platform_course_coupons_disabled_ck check (
    (is_enabled is true and disabled_at is null and disabled_by is null)
    or (is_enabled is false and disabled_at is not null and disabled_by is not null)
  )
);

create table if not exists public.platform_course_coupon_modules (
  coupon_id uuid not null references public.platform_course_coupons(id) on delete cascade,
  module_id uuid not null references public.platform_course_modules(id) on delete restrict,
  primary key (coupon_id, module_id)
);

create table if not exists public.platform_course_coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references public.platform_course_coupons(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  course_id uuid not null references public.platform_courses(id) on delete restrict,
  access_type text not null,
  module_ids uuid[] not null default '{}'::uuid[],
  redeemed_at timestamptz not null default now(),
  constraint platform_course_coupon_redemptions_coupon_key unique (coupon_id),
  constraint platform_course_coupon_redemptions_access_ck check (access_type in ('full_course', 'module_access'))
);

create table if not exists public.platform_course_module_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  course_id uuid not null references public.platform_courses(id) on delete cascade,
  module_id uuid not null references public.platform_course_modules(id) on delete cascade,
  grant_source text not null default 'coupon',
  source_coupon_id uuid references public.platform_course_coupons(id) on delete restrict,
  granted_by uuid references public.profiles(id) on delete set null,
  granted_at timestamptz not null default now(),
  constraint platform_course_module_entitlements_user_module_key unique (user_id, module_id),
  constraint platform_course_module_entitlements_source_ck check (grant_source in ('coupon', 'manual', 'payment', 'other'))
);

alter table public.platform_course_enrollments
  add column if not exists access_scope text,
  add column if not exists access_source text,
  add column if not exists source_coupon_id uuid references public.platform_course_coupons(id) on delete restrict;

update public.platform_course_enrollments
set
  access_scope = coalesce(access_scope, 'full'),
  access_source = coalesce(access_source, 'manual');

alter table public.platform_course_enrollments
  alter column access_scope set default 'full',
  alter column access_scope set not null,
  alter column access_source set default 'manual',
  alter column access_source set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'platform_course_enrollments_access_scope_ck'
      and conrelid = 'public.platform_course_enrollments'::regclass
  ) then
    alter table public.platform_course_enrollments
      add constraint platform_course_enrollments_access_scope_ck
      check (access_scope in ('full', 'partial')) not valid;
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'platform_course_enrollments_access_source_ck'
      and conrelid = 'public.platform_course_enrollments'::regclass
  ) then
    alter table public.platform_course_enrollments
      add constraint platform_course_enrollments_access_source_ck
      check (access_source in ('manual', 'coupon', 'request', 'payment', 'legacy', 'other')) not valid;
  end if;
end
$$;

alter table public.platform_course_enrollments
  validate constraint platform_course_enrollments_access_scope_ck;
alter table public.platform_course_enrollments
  validate constraint platform_course_enrollments_access_source_ck;

create index if not exists idx_platform_course_coupons_course_created
  on public.platform_course_coupons(course_id, created_at desc);
create index if not exists idx_platform_course_coupons_unused
  on public.platform_course_coupons(course_id, expires_at, created_at desc)
  where redeemed_at is null and is_enabled is true;
create index if not exists idx_platform_course_coupons_redeemed
  on public.platform_course_coupons(course_id, redeemed_at desc)
  where redeemed_at is not null;
create index if not exists idx_platform_course_coupon_modules_module
  on public.platform_course_coupon_modules(module_id, coupon_id);
create index if not exists idx_platform_course_coupon_redemptions_user_course
  on public.platform_course_coupon_redemptions(user_id, course_id, redeemed_at desc);
create index if not exists idx_platform_course_coupon_redemptions_course_time
  on public.platform_course_coupon_redemptions(course_id, redeemed_at desc);
create index if not exists idx_platform_module_entitlements_user_course
  on public.platform_course_module_entitlements(user_id, course_id, module_id);
create index if not exists idx_platform_module_entitlements_course_module
  on public.platform_course_module_entitlements(course_id, module_id);
create index if not exists idx_platform_enrollments_access_scope
  on public.platform_course_enrollments(user_id, course_id, access_scope);

-- Keep course/module relationships correct even for future privileged writers.
create or replace function private.validate_platform_module_relationships()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  actual_course_id uuid;
  coupon_course_id uuid;
begin
  select m.course_id into actual_course_id
  from public.platform_course_modules m
  where m.id = new.module_id;

  if actual_course_id is null or actual_course_id <> new.course_id then
    raise exception using errcode = '23514', message = 'MODULE_UNAVAILABLE';
  end if;

  if tg_table_name = 'platform_course_module_entitlements'
     and new.source_coupon_id is not null then
    select c.course_id into coupon_course_id
    from public.platform_course_coupons c
    where c.id = new.source_coupon_id;
    if coupon_course_id is null or coupon_course_id <> new.course_id then
      raise exception using errcode = '23514', message = 'COUPON_COURSE_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.validate_platform_module_relationships() from public, anon, authenticated;

drop trigger if exists trg_platform_module_entitlements_validate on public.platform_course_module_entitlements;
create trigger trg_platform_module_entitlements_validate
before insert or update of course_id, module_id, source_coupon_id
on public.platform_course_module_entitlements
for each row execute function private.validate_platform_module_relationships();

create or replace function private.validate_platform_coupon_module()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  coupon_course_id uuid;
  module_course_id uuid;
  coupon_kind text;
begin
  select c.course_id, c.coupon_type
  into coupon_course_id, coupon_kind
  from public.platform_course_coupons c
  where c.id = new.coupon_id;

  select m.course_id into module_course_id
  from public.platform_course_modules m
  where m.id = new.module_id;

  if coupon_kind <> 'module_access'
     or coupon_course_id is null
     or module_course_id is null
     or coupon_course_id <> module_course_id then
    raise exception using errcode = '23514', message = 'MODULE_UNAVAILABLE';
  end if;
  return new;
end;
$$;

revoke all on function private.validate_platform_coupon_module() from public, anon, authenticated;

drop trigger if exists trg_platform_coupon_modules_validate on public.platform_course_coupon_modules;
create trigger trg_platform_coupon_modules_validate
before insert or update on public.platform_course_coupon_modules
for each row execute function private.validate_platform_coupon_module();

-- ---------------------------------------------------------------------------
-- Central Video Courses access resolver used by RLS, RPCs, and Edge Functions.
-- ---------------------------------------------------------------------------

create or replace function private.is_active_platform_student()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'student'
      and p.approved is true
      and p.courses_access_enabled is true
  )
  and not private.is_app_feature_enabled('courses_coming_soon');
$$;

create or replace function private.has_full_platform_course_access(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_course_enrollments e
      where e.user_id = (select auth.uid())
        and e.course_id = target_course_id
        and e.access_scope = 'full'
    );
$$;

create or replace function private.has_any_platform_course_access(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and (
      exists (
        select 1
        from public.platform_course_enrollments e
        where e.user_id = (select auth.uid())
          and e.course_id = target_course_id
      )
      or exists (
        select 1
        from public.platform_course_module_entitlements me
        where me.user_id = (select auth.uid())
          and me.course_id = target_course_id
      )
    );
$$;

create or replace function private.has_platform_module_access(target_module_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_course_modules m
      join public.platform_courses c on c.id = m.course_id
      where m.id = target_module_id
        and m.is_published is true
        and c.is_active is true
        and c.is_published is true
        and (
          exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = m.course_id
              and e.access_scope = 'full'
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = m.course_id
              and me.module_id = m.id
          )
        )
    );
$$;

create or replace function private.can_access_platform_lesson(target_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_course_lessons l
      join public.platform_course_modules m
        on m.id = l.module_id and m.course_id = l.course_id
      join public.platform_courses c on c.id = l.course_id
      where l.id = target_lesson_id
        and l.is_published is true
        and m.is_published is true
        and c.is_active is true
        and c.is_published is true
        and (
          l.is_free_preview is true
          or exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = l.course_id
              and e.access_scope = 'full'
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = l.course_id
              and me.module_id = l.module_id
          )
        )
    );
$$;

create or replace function private.platform_suggestion_matches_current_profile(
  target_year integer,
  target_semester integer
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid())
        and (
          (target_year is null and target_semester is null)
          or (target_year = p.academic_year and target_semester is null)
          or (target_year = p.academic_year and target_semester = p.academic_semester)
        )
    );
$$;

create or replace function private.can_select_platform_course(
  target_course_id uuid,
  target_enrollment_mode text,
  target_is_active boolean,
  target_is_published boolean
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_platform_student()
    and target_is_active is true
    and target_is_published is true
    and (
      private.has_any_platform_course_access(target_course_id)
      or exists (
        select 1
        from public.platform_course_suggestions s
        join public.profiles p on p.id = (select auth.uid())
        where s.course_id = target_course_id
          and s.is_active is true
          and (s.starts_at is null or s.starts_at <= now())
          and (s.ends_at is null or s.ends_at >= now())
          and (
            (s.target_academic_year is null and s.target_semester is null)
            or (s.target_academic_year = p.academic_year and s.target_semester is null)
            or (s.target_academic_year = p.academic_year and s.target_semester = p.academic_semester)
          )
      )
    );
$$;

create or replace function private.can_select_platform_course_by_id(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_courses c
    where c.id = target_course_id
      and private.can_select_platform_course(c.id, c.enrollment_mode, c.is_active, c.is_published)
  );
$$;

create or replace function private.is_platform_course_requestable_for_current_student(target_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_select_platform_course_by_id(target_course_id)
    and not private.has_any_platform_course_access(target_course_id)
    and exists (
      select 1
      from public.platform_courses c
      where c.id = target_course_id
        and c.enrollment_mode = 'request'
    );
$$;

revoke all on function private.is_active_platform_student() from public, anon;
revoke all on function private.has_full_platform_course_access(uuid) from public, anon;
revoke all on function private.has_any_platform_course_access(uuid) from public, anon;
revoke all on function private.has_platform_module_access(uuid) from public, anon;
revoke all on function private.can_access_platform_lesson(uuid) from public, anon;
grant execute on function private.is_active_platform_student() to authenticated, service_role;
grant execute on function private.has_full_platform_course_access(uuid) to authenticated, service_role;
grant execute on function private.has_any_platform_course_access(uuid) to authenticated, service_role;
grant execute on function private.has_platform_module_access(uuid) to authenticated, service_role;
grant execute on function private.can_access_platform_lesson(uuid) to authenticated, service_role;

-- RLS changes: module metadata may be shown as locked, but lesson/resource rows
-- are returned only for a free preview, full-course access, or an entitled module.
drop policy if exists platform_modules_select_student_visible on public.platform_course_modules;
create policy platform_modules_select_student_visible
on public.platform_course_modules for select to authenticated
using (
  is_published is true
  and private.can_select_platform_course_by_id(course_id)
);

drop policy if exists platform_lessons_select_student_visible on public.platform_course_lessons;
create policy platform_lessons_select_student_visible
on public.platform_course_lessons for select to authenticated
using (
  is_published is true
  and (
    private.has_platform_module_access(module_id)
    or (is_free_preview is true and private.can_select_platform_course_by_id(course_id))
  )
);

drop policy if exists platform_resources_select_student_visible on public.platform_course_resources;
create policy platform_resources_select_student_visible
on public.platform_course_resources for select to authenticated
using (
  is_published is true
  and lesson_id is not null
  and private.can_access_platform_lesson(lesson_id)
);

drop policy if exists platform_announcements_select_student_visible on public.platform_course_announcements;
create policy platform_announcements_select_student_visible
on public.platform_course_announcements for select to authenticated
using (
  is_published is true
  and private.has_any_platform_course_access(course_id)
);

drop policy if exists platform_progress_insert_own on public.platform_lesson_progress;
create policy platform_progress_insert_own
on public.platform_lesson_progress for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.can_access_platform_lesson(lesson_id)
  and exists (
    select 1 from public.platform_course_lessons l
    where l.id = lesson_id and l.course_id = course_id
  )
);

drop policy if exists platform_progress_update_own on public.platform_lesson_progress;
create policy platform_progress_update_own
on public.platform_lesson_progress for update to authenticated
using (
  user_id = (select auth.uid())
  and private.can_access_platform_lesson(lesson_id)
)
with check (
  user_id = (select auth.uid())
  and private.can_access_platform_lesson(lesson_id)
  and exists (
    select 1 from public.platform_course_lessons l
    where l.id = lesson_id and l.course_id = course_id
  )
);

-- Private Video Course files are signed only after lesson-level authorization by
-- the course-video-url Edge Function. Module-linked materials can keep using
-- Storage signed URLs because their object path includes the lesson UUID.
drop policy if exists course_videos_student_select_visible_course on storage.objects;

drop policy if exists course_materials_student_select_visible_course on storage.objects;
create policy course_materials_student_select_visible_lesson
on storage.objects for select to authenticated
using (
  bucket_id = 'course-materials'
  and (storage.foldername(name))[1] = 'courses'
  and (storage.foldername(name))[3] = 'lessons'
  and coalesce((storage.foldername(name))[4], '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and private.can_access_platform_lesson(((storage.foldername(name))[4])::uuid)
);

alter table public.platform_course_coupons enable row level security;
alter table public.platform_course_coupon_modules enable row level security;
alter table public.platform_course_coupon_redemptions enable row level security;
alter table public.platform_course_module_entitlements enable row level security;

revoke all on public.platform_course_coupons from anon, authenticated;
revoke all on public.platform_course_coupon_modules from anon, authenticated;
revoke all on public.platform_course_coupon_redemptions from anon, authenticated;
revoke all on public.platform_course_module_entitlements from anon, authenticated;

grant select on public.platform_course_coupon_redemptions to authenticated;
grant select on public.platform_course_module_entitlements to authenticated;

create policy platform_coupon_redemptions_select_own
on public.platform_course_coupon_redemptions for select to authenticated
using (user_id = (select auth.uid()));

create policy platform_coupon_redemptions_select_admin
on public.platform_course_coupon_redemptions for select to authenticated
using ((select private.is_admin_user()));

create policy platform_module_entitlements_select_own
on public.platform_course_module_entitlements for select to authenticated
using (user_id = (select auth.uid()));

create policy platform_module_entitlements_select_admin
on public.platform_course_module_entitlements for select to authenticated
using ((select private.is_admin_user()));

-- ---------------------------------------------------------------------------
-- Secure coupon generation, redemption, access snapshot, and reporting RPCs.
-- ---------------------------------------------------------------------------

create or replace function private.normalize_platform_coupon_code(raw_code text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select upper(regexp_replace(coalesce(raw_code, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

create or replace function private.generate_platform_coupon_plaintext()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  raw_value text;
begin
  loop
    raw_value := upper(extensions.encode(extensions.gen_random_bytes(12), 'hex'));
    exit when raw_value !~ '[01]';
  end loop;
  return 'MBK-'
    || substr(raw_value, 1, 4) || '-'
    || substr(raw_value, 5, 4) || '-'
    || substr(raw_value, 9, 4) || '-'
    || substr(raw_value, 13, 4) || '-'
    || substr(raw_value, 17, 4) || '-'
    || substr(raw_value, 21, 4);
end;
$$;

revoke all on function private.normalize_platform_coupon_code(text) from public, anon, authenticated;
revoke all on function private.generate_platform_coupon_plaintext() from public, anon, authenticated;

create or replace function public.admin_generate_platform_course_coupons(
  p_course_id uuid,
  p_coupon_type text,
  p_module_ids uuid[] default '{}'::uuid[],
  p_quantity integer default 1,
  p_expires_at timestamptz default null,
  p_batch_name text default null,
  p_note text default null
)
returns table (
  coupon_id uuid,
  coupon_code text,
  code_preview text,
  coupon_type text,
  course_id uuid,
  module_ids uuid[],
  expires_at timestamptz,
  batch_name text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  normalized_type text := lower(btrim(coalesce(p_coupon_type, '')));
  normalized_modules uuid[] := '{}'::uuid[];
  plain_code text;
  normalized_code text;
  inserted_coupon public.platform_course_coupons%rowtype;
  counter integer;
begin
  if actor_id is null or not (select private.is_admin_user()) then
    raise exception using errcode = '42501', message = 'UNAUTHORIZED';
  end if;
  if normalized_type not in ('full_course', 'module_access') then
    raise exception using errcode = '22023', message = 'INVALID_COUPON_TYPE';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 500 then
    raise exception using errcode = '22023', message = 'INVALID_QUANTITY';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception using errcode = '22023', message = 'INVALID_EXPIRATION';
  end if;
  if not exists (select 1 from public.platform_courses c where c.id = p_course_id) then
    raise exception using errcode = '22023', message = 'COURSE_UNAVAILABLE';
  end if;

  if normalized_type = 'module_access' then
    select coalesce(array_agg(distinct source.module_id order by source.module_id), '{}'::uuid[])
    into normalized_modules
    from unnest(coalesce(p_module_ids, '{}'::uuid[])) as source(module_id);

    if cardinality(normalized_modules) = 0
       or (
         select count(*)
         from public.platform_course_modules m
         where m.course_id = p_course_id and m.id = any(normalized_modules)
       ) <> cardinality(normalized_modules) then
      raise exception using errcode = '22023', message = 'MODULE_UNAVAILABLE';
    end if;
  else
    normalized_modules := '{}'::uuid[];
  end if;

  for counter in 1..p_quantity loop
    loop
      plain_code := private.generate_platform_coupon_plaintext();
      normalized_code := private.normalize_platform_coupon_code(plain_code);
      begin
        insert into public.platform_course_coupons (
          course_id,
          code_hash,
          code_preview,
          coupon_type,
          expires_at,
          batch_name,
          note,
          created_by
        ) values (
          p_course_id,
          extensions.digest(normalized_code, 'sha256'),
          right(normalized_code, 4),
          normalized_type,
          p_expires_at,
          nullif(btrim(p_batch_name), ''),
          nullif(btrim(p_note), ''),
          actor_id
        ) returning * into inserted_coupon;
        exit;
      exception when unique_violation then
        -- Cryptographically improbable, but retry makes generation total.
      end;
    end loop;

    if normalized_type = 'module_access' then
      insert into public.platform_course_coupon_modules (coupon_id, module_id)
      select inserted_coupon.id, module_id
      from unnest(normalized_modules) as module_id;
    end if;

    coupon_id := inserted_coupon.id;
    coupon_code := plain_code;
    code_preview := inserted_coupon.code_preview;
    coupon_type := inserted_coupon.coupon_type;
    course_id := inserted_coupon.course_id;
    module_ids := normalized_modules;
    expires_at := inserted_coupon.expires_at;
    batch_name := inserted_coupon.batch_name;
    created_at := inserted_coupon.created_at;
    return next;
  end loop;
end;
$$;

revoke all on function public.admin_generate_platform_course_coupons(uuid, text, uuid[], integer, timestamptz, text, text) from public, anon;
grant execute on function public.admin_generate_platform_course_coupons(uuid, text, uuid[], integer, timestamptz, text, text) to authenticated, service_role;

create or replace function public.redeem_platform_course_coupon(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  normalized_code text := private.normalize_platform_coupon_code(p_code);
  coupon_row public.platform_course_coupons%rowtype;
  course_row public.platform_courses%rowtype;
  module_ids uuid[] := '{}'::uuid[];
  module_titles text[] := '{}'::text[];
  mapped_module_count integer := 0;
  valid_module_count integer := 0;
  already_full boolean := false;
  already_module_count integer := 0;
begin
  if actor_id is null then
    return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
  end if;
  if length(normalized_code) < 20 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_COUPON');
  end if;

  begin
    select * into coupon_row
    from public.platform_course_coupons c
    where c.code_hash = extensions.digest(normalized_code, 'sha256')
    for update;

    if not found then
      return jsonb_build_object('ok', false, 'code', 'INVALID_COUPON');
    end if;
    if coupon_row.redeemed_at is not null then
      return jsonb_build_object('ok', false, 'code', 'COUPON_ALREADY_USED');
    end if;
    if coupon_row.is_enabled is not true then
      return jsonb_build_object('ok', false, 'code', 'COUPON_DISABLED');
    end if;
    if coupon_row.expires_at is not null and coupon_row.expires_at <= now() then
      return jsonb_build_object('ok', false, 'code', 'COUPON_EXPIRED');
    end if;
    if not exists (
      select 1 from public.profiles p
      where p.id = actor_id
        and p.role = 'student'
        and p.approved is true
        and p.courses_access_enabled is true
    ) then
      return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
    end if;

    select * into course_row
    from public.platform_courses c
    where c.id = coupon_row.course_id;
    if not found or course_row.is_active is not true or course_row.is_published is not true then
      return jsonb_build_object('ok', false, 'code', 'COURSE_UNAVAILABLE');
    end if;

    select exists (
      select 1
      from public.platform_course_enrollments e
      where e.user_id = actor_id
        and e.course_id = coupon_row.course_id
        and e.access_scope = 'full'
    ) into already_full;

    if coupon_row.coupon_type = 'module_access' then
      select count(*) into mapped_module_count
      from public.platform_course_coupon_modules cm
      where cm.coupon_id = coupon_row.id;

      select
        coalesce(array_agg(m.id order by m.position, m.id), '{}'::uuid[]),
        coalesce(array_agg(m.title order by m.position, m.id), '{}'::text[]),
        count(*)
      into module_ids, module_titles, valid_module_count
      from public.platform_course_coupon_modules cm
      join public.platform_course_modules m on m.id = cm.module_id
      where cm.coupon_id = coupon_row.id
        and m.course_id = coupon_row.course_id
        and m.is_published is true;

      if mapped_module_count = 0 or valid_module_count <> mapped_module_count then
        return jsonb_build_object('ok', false, 'code', 'MODULE_UNAVAILABLE');
      end if;
      if already_full then
        return jsonb_build_object('ok', false, 'code', 'ALREADY_HAS_ACCESS');
      end if;

      select count(*) into already_module_count
      from public.platform_course_module_entitlements me
      where me.user_id = actor_id
        and me.course_id = coupon_row.course_id
        and me.module_id = any(module_ids);

      if already_module_count = cardinality(module_ids) then
        return jsonb_build_object('ok', false, 'code', 'ALREADY_HAS_ACCESS');
      end if;

      insert into public.platform_course_enrollments (
        user_id, course_id, assigned_by, access_scope, access_source, source_coupon_id
      ) values (
        actor_id, coupon_row.course_id, null, 'partial', 'coupon', coupon_row.id
      )
      on conflict (user_id, course_id) do update
      set
        access_scope = case
          when public.platform_course_enrollments.access_scope = 'full' then 'full'
          else 'partial'
        end,
        access_source = case
          when public.platform_course_enrollments.access_scope = 'full'
            then public.platform_course_enrollments.access_source
          else 'coupon'
        end,
        source_coupon_id = case
          when public.platform_course_enrollments.access_scope = 'full'
            then public.platform_course_enrollments.source_coupon_id
          else coupon_row.id
        end;

      insert into public.platform_course_module_entitlements (
        user_id, course_id, module_id, grant_source, source_coupon_id, granted_by
      )
      select actor_id, coupon_row.course_id, module_id, 'coupon', coupon_row.id, null
      from unnest(module_ids) as module_id
      on conflict (user_id, module_id) do nothing;
    else
      if already_full then
        return jsonb_build_object('ok', false, 'code', 'ALREADY_HAS_ACCESS');
      end if;

      insert into public.platform_course_enrollments (
        user_id, course_id, assigned_by, access_scope, access_source, source_coupon_id
      ) values (
        actor_id, coupon_row.course_id, null, 'full', 'coupon', coupon_row.id
      )
      on conflict (user_id, course_id) do update
      set access_scope = 'full', access_source = 'coupon', source_coupon_id = coupon_row.id;

      select
        coalesce(array_agg(m.id order by m.position, m.id), '{}'::uuid[]),
        coalesce(array_agg(m.title order by m.position, m.id), '{}'::text[])
      into module_ids, module_titles
      from public.platform_course_modules m
      where m.course_id = coupon_row.course_id and m.is_published is true;
    end if;

    insert into public.platform_course_coupon_redemptions (
      coupon_id, user_id, course_id, access_type, module_ids
    ) values (
      coupon_row.id, actor_id, coupon_row.course_id, coupon_row.coupon_type, module_ids
    );

    update public.platform_course_coupons
    set redeemed_by = actor_id, redeemed_at = now()
    where id = coupon_row.id;

    return jsonb_build_object(
      'ok', true,
      'code', 'SUCCESS',
      'course_id', course_row.id,
      'course_name', course_row.course_name,
      'access_type', coupon_row.coupon_type,
      'module_ids', to_jsonb(module_ids),
      'module_titles', to_jsonb(module_titles)
    );
  exception
    when unique_violation then
      return jsonb_build_object('ok', false, 'code', 'COUPON_ALREADY_USED');
    when others then
      return jsonb_build_object('ok', false, 'code', 'REDEMPTION_FAILED');
  end;
end;
$$;

revoke all on function public.redeem_platform_course_coupon(text) from public, anon;
grant execute on function public.redeem_platform_course_coupon(text) to authenticated, service_role;

create or replace function public.get_my_platform_course_access()
returns table (
  course_id uuid,
  access_scope text,
  access_source text,
  module_ids uuid[]
)
language sql
stable
security definer
set search_path = ''
as $$
  with accessible_courses as (
    select e.course_id
    from public.platform_course_enrollments e
    where e.user_id = (select auth.uid())
    union
    select me.course_id
    from public.platform_course_module_entitlements me
    where me.user_id = (select auth.uid())
  )
  select
    ac.course_id,
    case when bool_or(coalesce(e.access_scope = 'full', false)) then 'full' else 'partial' end,
    case
      when bool_or(coalesce(e.access_scope = 'full', false))
        then max(e.access_source) filter (where e.access_scope = 'full')
      else 'coupon'
    end,
    case
      when bool_or(coalesce(e.access_scope = 'full', false)) then coalesce((
        select array_agg(m.id order by m.position, m.id)
        from public.platform_course_modules m
        where m.course_id = ac.course_id and m.is_published is true
      ), '{}'::uuid[])
      else coalesce((
        select array_agg(me.module_id order by m.position, me.module_id)
        from public.platform_course_module_entitlements me
        join public.platform_course_modules m on m.id = me.module_id
        where me.user_id = (select auth.uid())
          and me.course_id = ac.course_id
          and m.is_published is true
      ), '{}'::uuid[])
    end
  from accessible_courses ac
  left join public.platform_course_enrollments e
    on e.user_id = (select auth.uid()) and e.course_id = ac.course_id
  where (select auth.uid()) is not null
  group by ac.course_id;
$$;

revoke all on function public.get_my_platform_course_access() from public, anon;
grant execute on function public.get_my_platform_course_access() to authenticated, service_role;

create or replace function public.admin_disable_platform_course_coupon(p_coupon_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  affected integer;
begin
  if actor_id is null or not (select private.is_admin_user()) then
    return jsonb_build_object('ok', false, 'code', 'UNAUTHORIZED');
  end if;

  update public.platform_course_coupons
  set is_enabled = false, disabled_by = actor_id, disabled_at = now()
  where id = p_coupon_id
    and redeemed_at is null
    and is_enabled is true;
  get diagnostics affected = row_count;

  if affected = 0 then
    return jsonb_build_object('ok', false, 'code', 'COUPON_NOT_DISABLEABLE');
  end if;
  return jsonb_build_object('ok', true, 'code', 'SUCCESS');
end;
$$;

revoke all on function public.admin_disable_platform_course_coupon(uuid) from public, anon;
grant execute on function public.admin_disable_platform_course_coupon(uuid) to authenticated, service_role;

create or replace function public.admin_list_platform_course_coupons(
  p_course_id uuid default null,
  p_coupon_type text default null,
  p_status text default null,
  p_search text default null,
  p_created_from timestamptz default null,
  p_created_to timestamptz default null,
  p_redeemed_from timestamptz default null,
  p_redeemed_to timestamptz default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  course_id uuid,
  course_name text,
  coupon_type text,
  code_preview text,
  status text,
  is_enabled boolean,
  expires_at timestamptz,
  batch_name text,
  note text,
  created_at timestamptz,
  redeemed_at timestamptz,
  redeemed_by uuid,
  redeemed_public_user_id bigint,
  redeemed_name text,
  module_ids uuid[],
  module_titles text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not (select private.is_admin_user()) then
    raise exception using errcode = '42501', message = 'UNAUTHORIZED';
  end if;

  return query
  with coupon_rows as (
    select
      c.*,
      pc.course_name,
      p.public_user_id,
      p.full_name,
      case
        when c.redeemed_at is not null then 'used'
        when c.is_enabled is false then 'disabled'
        when c.expires_at is not null and c.expires_at <= now() then 'expired'
        else 'unused'
      end as calculated_status,
      coalesce(array_agg(m.id order by m.position, m.id) filter (where m.id is not null), '{}'::uuid[]) as linked_module_ids,
      coalesce(array_agg(m.title order by m.position, m.id) filter (where m.id is not null), '{}'::text[]) as linked_module_titles
    from public.platform_course_coupons c
    join public.platform_courses pc on pc.id = c.course_id
    left join public.profiles p on p.id = c.redeemed_by
    left join public.platform_course_coupon_modules cm on cm.coupon_id = c.id
    left join public.platform_course_modules m on m.id = cm.module_id
    group by c.id, pc.course_name, p.public_user_id, p.full_name
  )
  select
    cr.id,
    cr.course_id,
    cr.course_name,
    cr.coupon_type,
    cr.code_preview::text,
    cr.calculated_status,
    cr.is_enabled,
    cr.expires_at,
    cr.batch_name,
    cr.note,
    cr.created_at,
    cr.redeemed_at,
    cr.redeemed_by,
    cr.public_user_id,
    cr.full_name,
    cr.linked_module_ids,
    cr.linked_module_titles,
    count(*) over()
  from coupon_rows cr
  where (p_course_id is null or cr.course_id = p_course_id)
    and (nullif(btrim(p_coupon_type), '') is null or cr.coupon_type = lower(btrim(p_coupon_type)))
    and (
      nullif(btrim(p_status), '') is null
      or lower(btrim(p_status)) = 'all'
      or cr.calculated_status = lower(btrim(p_status))
      or (lower(btrim(p_status)) = 'valid' and cr.calculated_status = 'unused')
    )
    and (
      nullif(btrim(p_search), '') is null
      or cr.code_preview ilike '%' || btrim(p_search) || '%'
      or coalesce(cr.batch_name, '') ilike '%' || btrim(p_search) || '%'
      or coalesce(cr.full_name, '') ilike '%' || btrim(p_search) || '%'
      or coalesce(cr.public_user_id::text, '') = regexp_replace(btrim(p_search), '\D', '', 'g')
    )
    and (p_created_from is null or cr.created_at >= p_created_from)
    and (p_created_to is null or cr.created_at <= p_created_to)
    and (p_redeemed_from is null or cr.redeemed_at >= p_redeemed_from)
    and (p_redeemed_to is null or cr.redeemed_at <= p_redeemed_to)
  order by cr.created_at desc, cr.id
  limit greatest(1, least(coalesce(p_limit, 100), 500))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

revoke all on function public.admin_list_platform_course_coupons(uuid, text, text, text, timestamptz, timestamptz, timestamptz, timestamptz, integer, integer) from public, anon;
grant execute on function public.admin_list_platform_course_coupons(uuid, text, text, text, timestamptz, timestamptz, timestamptz, timestamptz, integer, integer) to authenticated, service_role;

create or replace function public.admin_get_platform_course_coupon_stats(p_course_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if (select auth.uid()) is null or not (select private.is_admin_user()) then
    raise exception using errcode = '42501', message = 'UNAUTHORIZED';
  end if;

  with filtered as (
    select c.*
    from public.platform_course_coupons c
    where p_course_id is null or c.course_id = p_course_id
  ), totals as (
    select
      count(*) as total,
      count(*) filter (where coupon_type = 'full_course') as full_course,
      count(*) filter (where coupon_type = 'module_access') as module_access,
      count(*) filter (where redeemed_at is not null) as redeemed,
      count(*) filter (
        where redeemed_at is null and is_enabled is true
          and (expires_at is null or expires_at > now())
      ) as unused,
      count(*) filter (where redeemed_at is null and expires_at is not null and expires_at <= now()) as expired,
      count(*) filter (where redeemed_at is null and is_enabled is false) as disabled,
      count(distinct redeemed_by) filter (where redeemed_by is not null) as students
    from filtered
  ), timeline as (
    select coalesce(jsonb_agg(jsonb_build_object('day', day, 'count', count) order by day), '[]'::jsonb) as rows
    from (
      select date_trunc('day', redeemed_at)::date as day, count(*) as count
      from filtered
      where redeemed_at is not null
      group by 1
      order by 1 desc
      limit 90
    ) source
  ), by_module as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'module_id', source.module_id,
      'module_title', source.module_title,
      'redemptions', source.redemptions
    ) order by source.redemptions desc, source.module_title), '[]'::jsonb) as rows
    from (
      select m.id as module_id, m.title as module_title, count(*) as redemptions
      from filtered f
      join public.platform_course_coupon_modules cm on cm.coupon_id = f.id
      join public.platform_course_modules m on m.id = cm.module_id
      where f.redeemed_at is not null
      group by m.id, m.title
      order by count(*) desc, m.title
    ) source
  ), recent as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'coupon_id', source.coupon_id,
      'course_id', source.course_id,
      'course_name', source.course_name,
      'coupon_type', source.coupon_type,
      'redeemed_at', source.redeemed_at,
      'user_id', source.user_id,
      'public_user_id', source.public_user_id,
      'student_name', source.full_name
    ) order by source.redeemed_at desc), '[]'::jsonb) as rows
    from (
      select
        f.id as coupon_id,
        f.course_id,
        pc.course_name,
        f.coupon_type,
        f.redeemed_at,
        f.redeemed_by as user_id,
        p.public_user_id,
        p.full_name
      from filtered f
      join public.platform_courses pc on pc.id = f.course_id
      join public.profiles p on p.id = f.redeemed_by
      where f.redeemed_at is not null
      order by f.redeemed_at desc
      limit 20
    ) source
  )
  select jsonb_build_object(
    'total', t.total,
    'full_course', t.full_course,
    'module_access', t.module_access,
    'redeemed', t.redeemed,
    'unused', t.unused,
    'expired', t.expired,
    'disabled', t.disabled,
    'students', t.students,
    'redemption_rate', case when t.total = 0 then 0 else round((t.redeemed::numeric / t.total::numeric) * 100, 1) end,
    'redemptions_over_time', tl.rows,
    'redemptions_by_module', bm.rows,
    'recent_redemptions', r.rows
  )
  into result
  from totals t cross join timeline tl cross join by_module bm cross join recent r;

  return coalesce(result, '{}'::jsonb);
end;
$$;

revoke all on function public.admin_get_platform_course_coupon_stats(uuid) from public, anon;
grant execute on function public.admin_get_platform_course_coupon_stats(uuid) to authenticated, service_role;

comment on table public.platform_course_coupons is
  'One-time Video Course activation coupons. Only SHA-256 hashes are stored; plaintext is returned once at generation.';
comment on table public.platform_course_module_entitlements is
  'Additive per-module access. Full platform_course_enrollments override these grants and include future published modules.';
comment on function public.redeem_platform_course_coupon(text) is
  'Atomically claims one coupon for auth.uid(), grants non-downgrading access, and writes an audit redemption.';

commit;
