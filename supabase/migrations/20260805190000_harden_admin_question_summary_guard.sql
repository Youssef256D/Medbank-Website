-- ---------------------------------------------------------------------------
-- Align get_admin_question_count_summary with every other admin RPC.
--
-- It checked `role = 'admin'` inline but never checked `approved`, so an
-- unapproved admin account could read question-count summaries. Every other
-- admin function goes through private.is_admin_user(), which requires both.
-- All current admins are approved, so nobody loses access.
--
-- Also revokes anon EXECUTE: Supabase's default privileges grant it on public
-- schema functions, and `revoke ... from public` does not undo a direct grant.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.get_admin_question_count_summary()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  summary jsonb;
begin
  if not private.is_admin_user() then
    raise exception 'Only admins can read question count summaries.'
      using errcode = '42501';
  end if;

  with question_base as (
    select
      q.id,
      q.status::text as status,
      q.created_at,
      coalesce(nullif(trim(c.course_name), ''), '(No course)') as course_name,
      coalesce(nullif(trim(ct.topic_name), ''), '(No topic)') as topic_name,
      exists (
        select 1 from public.question_choices qc where qc.question_id = q.id
      ) as has_choices,
      exists (
        select 1 from public.question_choices qc
        where qc.question_id = q.id and qc.is_correct
      ) as has_correct
    from public.questions q
    left join public.courses c on c.id = q.course_id
    left join public.course_topics ct on ct.id = q.topic_id
  ),
  totals as (
    select
      count(*)::int as total,
      count(*) filter (where status = 'published')::int as published,
      count(*) filter (where status = 'published' and has_choices and has_correct)::int as published_usable,
      count(*) filter (where status = 'published' and not (has_choices and has_correct))::int as published_unusable,
      count(*) filter (where status = 'draft')::int as draft,
      count(*) filter (where status = 'archived')::int as archived,
      max(created_at) as latest_question_at
    from question_base
  ),
  course_counts as (
    select
      course_name,
      count(*)::int as total,
      count(*) filter (where status = 'published')::int as published,
      count(*) filter (where status = 'published' and has_choices and has_correct)::int as published_usable,
      count(*) filter (where status = 'published' and not (has_choices and has_correct))::int as published_unusable,
      count(*) filter (where status = 'draft')::int as draft,
      count(*) filter (where status = 'archived')::int as archived
    from question_base
    group by course_name
  ),
  topic_counts as (
    select
      course_name,
      topic_name,
      count(*)::int as total,
      count(*) filter (where status = 'published')::int as published,
      count(*) filter (where status = 'published' and has_choices and has_correct)::int as published_usable,
      count(*) filter (where status = 'published' and not (has_choices and has_correct))::int as published_unusable,
      count(*) filter (where status = 'draft')::int as draft,
      count(*) filter (where status = 'archived')::int as archived
    from question_base
    group by course_name, topic_name
  )
  select jsonb_build_object(
    'generatedAt', now(),
    'totals', coalesce((select to_jsonb(t) from totals t), '{}'::jsonb),
    'byCourse', coalesce((
      select jsonb_agg(to_jsonb(cc) order by cc.published_usable desc, cc.total desc, cc.course_name)
      from course_counts cc
    ), '[]'::jsonb),
    'byTopic', coalesce((
      select jsonb_agg(to_jsonb(tc) order by tc.course_name, tc.published_usable desc, tc.total desc, tc.topic_name)
      from topic_counts tc
    ), '[]'::jsonb)
  )
  into summary;

  return summary;
end;
$function$;

revoke execute on function public.get_admin_question_count_summary() from anon;

commit;
