-- Time spent: 0 means "not recorded", not "no time". The app always sends
-- 0 (it does not time questions), and those zeros pulled every average down.
-- Store them as null, like the junk values over an hour.

-- Rebuilds the rows for one finished test. Returns how many were written.
create or replace function private.refresh_test_history_answers(p_history_id uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_entry record;
  v_responses jsonb;
  v_snapshots jsonb;
  v_client text;
  v_written integer := 0;
begin
  delete from public.test_history_answers where history_id = p_history_id;

  select h.id, h.user_id, h.course_id, h.status, h.payload,
         coalesce(h.completed_at, h.updated_at, h.created_at) as finished_at
    into v_entry
  from public.test_history_entries h
  join public.profiles p on p.id = h.user_id
  where h.id = p_history_id;

  if not found or v_entry.status is distinct from 'completed' then
    return 0;
  end if;

  -- Read the payload once; every lookup below uses these copies.
  v_responses := case when jsonb_typeof(v_entry.payload -> 'responses') = 'object'
    then v_entry.payload -> 'responses' else '{}'::jsonb end;
  v_snapshots := case when jsonb_typeof(v_entry.payload -> 'questionSnapshots') = 'object'
    then v_entry.payload -> 'questionSnapshots' else '{}'::jsonb end;
  -- The website writes originSessionId into every payload; the app never does.
  v_client := case when v_entry.payload ? 'originSessionId' then 'website' else 'app' end;

  insert into public.test_history_answers (
    history_id, question_key, user_id, question_id, course_id, topic_id,
    course_name, topic_name, selected_labels, correct_labels, is_correct,
    flagged, time_spent_sec, client, completed_at
  )
  select
    v_entry.id,
    r.key,
    v_entry.user_id,
    coalesce(q.id, private.results_try_uuid(snap.value ->> 'dbId'), private.results_try_uuid(r.key)),
    coalesce(q.course_id, v_entry.course_id),
    q.topic_id,
    nullif(btrim(coalesce(snap.value ->> 'course', snap.value ->> 'qbankCourse', '')), ''),
    nullif(btrim(coalesce(snap.value ->> 'topic', snap.value ->> 'qbankTopic', '')), ''),
    sel.labels,
    cor.labels,
    cardinality(cor.labels) > 0 and sel.labels = cor.labels,
    coalesce(r.value -> 'flagged' = 'true'::jsonb, false),
    case
      when jsonb_typeof(r.value -> 'timeSpentSec') = 'number'
       and (r.value ->> 'timeSpentSec')::numeric between 1 and 3600
        then round((r.value ->> 'timeSpentSec')::numeric)::integer
    end,
    v_client,
    v_entry.finished_at
  from jsonb_each(v_responses) as r (key, value)
  cross join lateral (select v_snapshots -> r.key as value) as snap
  cross join lateral (select private.results_label_set(r.value -> 'selected') as labels) as sel
  left join lateral (
    select m.id, m.course_id, m.topic_id
    from (
      select q1.id, q1.course_id, q1.topic_id, 1 as rank
      from public.questions q1
      where q1.id = private.results_try_uuid(snap.value ->> 'dbId')
      union all
      select q2.id, q2.course_id, q2.topic_id, 2
      from public.questions q2
      where q2.id = private.results_try_uuid(r.key)
      union all
      select q3.id, q3.course_id, q3.topic_id, 3
      from public.questions q3
      where q3.external_id = r.key
    ) as m
    order by m.rank
    limit 1
  ) as q on true
  -- The answer key the student saw; the current one only when the test kept no copy.
  cross join lateral (
    select coalesce(
      nullif(private.results_label_set(snap.value -> 'correct'), '{}'),
      coalesce(array(
        select distinct upper(btrim(c.choice_label))
        from public.question_choices c
        where c.question_id = q.id and c.is_correct
        order by 1
      ), '{}')
    ) as labels
  ) as cor
  where jsonb_typeof(r.value) = 'object'
    and cardinality(sel.labels) > 0;

  get diagnostics v_written = row_count;
  return v_written;
end;
$$;

update public.test_history_answers
set time_spent_sec = null
where time_spent_sec = 0;
