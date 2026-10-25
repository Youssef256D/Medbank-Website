-- Users page "Last test" column: for up to 200 students at once, their
-- number of finished tests and their latest one with its score. Same access
-- as the other admin_results_* functions (People area); reads only.

create or replace function public.admin_results_last_tests(p_user_ids uuid[])
returns table (
  user_id uuid,
  tests bigint,
  last_test_id uuid,
  last_test_at timestamptz,
  last_test_name text,
  last_question_count integer,
  last_answered bigint,
  last_correct bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
#variable_conflict use_column
begin
  if not private.admin_has_area('people') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  return query
  with ids as (
    select distinct x.id
    from unnest((coalesce(p_user_ids, '{}'::uuid[]))[1:200]) as x (id)
  ),
  finished as (
    select h.user_id, h.id, h.session_name, h.question_count,
           coalesce(h.completed_at, h.updated_at) as finished_at
    from public.test_history_entries h
    join ids on ids.id = h.user_id
    where h.status = 'completed'
  ),
  latest as (
    select distinct on (f.user_id) f.*
    from finished f
    order by f.user_id, f.finished_at desc
  ),
  counts as (
    select f.user_id, count(*) as n
    from finished f
    group by f.user_id
  )
  select l.user_id, c.n, l.id, l.finished_at, l.session_name, l.question_count,
         (select count(*) from public.test_history_answers a where a.history_id = l.id),
         (select count(*) from public.test_history_answers a where a.history_id = l.id and a.is_correct)
  from latest l
  join counts c on c.user_id = l.user_id;
end;
$$;

revoke all on function public.admin_results_last_tests(uuid[]) from public, anon;
grant execute on function public.admin_results_last_tests(uuid[]) to authenticated;
