-- Rollback for 20260706120000_add_content_versions.sql
drop trigger if exists trg_questions_bump_content_version on public.questions;
drop trigger if exists trg_question_choices_bump_content_version on public.question_choices;
drop function if exists public.bump_question_content_version();
do $$
begin
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'content_versions'
  ) then
    alter publication supabase_realtime drop table public.content_versions;
  end if;
end;
$$;
drop table if exists public.content_versions;
