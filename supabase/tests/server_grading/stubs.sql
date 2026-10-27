-- Minimal stand-in for the hosted schema, only what the server-side grading
-- migration touches. Used by run-local.sh against a throwaway local Postgres;
-- never run against the hosted project.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create schema private;
grant usage on schema public, private, auth to anon, authenticated;

-- auth.uid() reads the user id the test sets with set_config.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid
$$;
grant execute on function auth.uid() to anon, authenticated;

create type public.app_question_status as enum ('draft', 'published', 'archived');
create type public.app_block_mode as enum ('tutor', 'timed');
create type public.app_block_status as enum ('in_progress', 'completed', 'suspended');

create table public.profiles (id uuid primary key, role text not null default 'student');
create table public.courses (id uuid primary key, course_name text);
create table public.course_topics (id uuid primary key, course_id uuid references public.courses, topic_name text);
create table public.questions (
  id uuid primary key default gen_random_uuid(),
  course_id uuid, topic_id uuid, author_id uuid, stem text, explanation text,
  objective text, difficulty smallint, status public.app_question_status,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  external_id text, question_image_url text, explanation_image_url text,
  sort_order integer
);
create table public.question_choices (
  id uuid primary key default gen_random_uuid(),
  question_id uuid references public.questions on delete cascade,
  choice_label text, choice_text text, is_correct boolean
);
create table public.test_blocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid, course_id uuid, mode public.app_block_mode,
  status public.app_block_status default 'in_progress'
);
create table public.test_block_items (
  block_id uuid references public.test_blocks on delete cascade,
  position integer, question_id uuid,
  primary key (block_id, question_id)
);
create table public.test_responses (
  block_id uuid, question_id uuid, selected_choice_labels text[],
  flagged boolean default false, notes text, submitted boolean default false,
  answered_at timestamptz,
  primary key (block_id, question_id),
  foreign key (block_id, question_id) references public.test_block_items (block_id, question_id) on delete cascade
);
grant select, insert, update, delete on all tables in schema public to authenticated;

-- Topics in this table are "locked" for every student.
create table private.locked_topics (topic_id uuid primary key);

create function private.is_admin_user() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;
create function private.can_current_user_access_mcq() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(current_setting('test.no_mcq', true), '') <> 'on'
$$;
create function private.can_current_user_access_question(target_course_id uuid, target_topic_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from private.locked_topics where topic_id = target_topic_id)
$$;
-- Live definition (2026-10-27).
create function private.can_current_user_access_question_choice(target_question_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.questions q
    where q.id = target_question_id
      and q.status = 'published'::public.app_question_status
      and private.can_current_user_access_question(q.course_id, q.topic_id)
  );
$$;
grant execute on all functions in schema private to authenticated;

-- 2026-10-25 trigger as live.
create function private.protect_test_response_answer() returns trigger language plpgsql as $$
begin
  return new;
end;
$$;
create trigger trg_protect_test_response_answer
  before insert or update on public.test_responses
  for each row execute function private.protect_test_response_answer();

-- Live RLS (simplified to what matters here).
alter table public.questions enable row level security;
alter table public.question_choices enable row level security;
alter table public.test_blocks enable row level security;
alter table public.test_block_items enable row level security;
alter table public.test_responses enable row level security;
create policy blocks_all on public.test_blocks for all to authenticated
  using (user_id = auth.uid() or private.is_admin_user())
  with check (user_id = auth.uid() or private.is_admin_user());
create policy items_all on public.test_block_items for all to authenticated
  using (exists (select 1 from public.test_blocks b where b.id = block_id and (b.user_id = auth.uid() or private.is_admin_user())))
  with check (exists (select 1 from public.test_blocks b where b.id = block_id and b.user_id = auth.uid()));
create policy responses_all on public.test_responses for all to authenticated
  using (exists (select 1 from public.test_blocks b where b.id = block_id and (b.user_id = auth.uid() or private.is_admin_user())))
  with check (exists (select 1 from public.test_blocks b where b.id = block_id and b.user_id = auth.uid()));

-- Catalog wrappers as live (they call the private functions the migration replaces).
create function private.accessible_catalog_rows(only_ids uuid[] default null, after_id uuid default null, row_limit integer default null)
returns table(id uuid, external_id text, course_id uuid, topic_id uuid, author_id uuid, stem text, explanation text, objective text, difficulty smallint, status public.app_question_status, created_at timestamptz, sort_order integer, question_image_url text, explanation_image_url text, course_name text, topic_name text, choices jsonb)
language sql as $$ select null::uuid, null, null::uuid, null::uuid, null::uuid, null, null, null, null::smallint, null::public.app_question_status, null::timestamptz, null::int, null, null, null, null, null::jsonb where false $$;
create function public.get_question_catalog_page_after(after_id uuid default null, requested_limit integer default 1000)
returns table(id uuid, external_id text, course_id uuid, topic_id uuid, author_id uuid, stem text, explanation text, objective text, difficulty smallint, status public.app_question_status, created_at timestamptz, sort_order integer, question_image_url text, explanation_image_url text, course_name text, topic_name text, choices jsonb)
language sql stable security definer set search_path = '' as $$
  select * from private.accessible_catalog_rows(null, after_id, greatest(1, least(coalesce(requested_limit, 1000), 1000)));
$$;
grant execute on function public.get_question_catalog_page_after(uuid, integer) to authenticated;
