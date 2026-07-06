-- Adds a lightweight content-version signal so student clients can detect new
-- or changed questions automatically instead of relying on a hardcoded
-- frontend refresh-version constant or manual admin broadcasts.
--
-- content_versions is a tiny table (one row per scope). Statement-level
-- triggers on questions/question_choices bump the 'questions' scope version;
-- clients read the single row (cheap) and re-hydrate the catalog when it
-- moves. The table is added to the realtime publication for instant push.

create table if not exists public.content_versions (
  scope text primary key,
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);

insert into public.content_versions (scope)
values ('questions')
on conflict (scope) do nothing;

alter table public.content_versions enable row level security;

drop policy if exists content_versions_select_authenticated on public.content_versions;
create policy content_versions_select_authenticated
  on public.content_versions
  for select
  to authenticated
  using (true);
-- No insert/update/delete policies: only the definer trigger function writes.

create or replace function public.bump_question_content_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.content_versions
     set version = version + 1,
         updated_at = now()
   where scope = 'questions';
  return null;
end;
$$;

revoke execute on function public.bump_question_content_version() from public, anon, authenticated;

drop trigger if exists trg_questions_bump_content_version on public.questions;
create trigger trg_questions_bump_content_version
  after insert or update or delete on public.questions
  for each statement execute function public.bump_question_content_version();

drop trigger if exists trg_question_choices_bump_content_version on public.question_choices;
create trigger trg_question_choices_bump_content_version
  after insert or update or delete on public.question_choices
  for each statement execute function public.bump_question_content_version();

-- Realtime push for the one-row table (safe if already added).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'content_versions'
  ) then
    alter publication supabase_realtime add table public.content_versions;
  end if;
end;
$$;
