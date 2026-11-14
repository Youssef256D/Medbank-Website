-- Additive contract: legacy clients retain their existing RPCs. New clients
-- must use this RPC for finalization; it has no multi-request fallback.
create table private.test_finalizations (
  block_id uuid primary key references public.test_blocks(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table private.test_finalizations enable row level security;
revoke all on private.test_finalizations from public, anon, authenticated;

create function private.finalize_test_block(
  p_block_id uuid,
  p_rows jsonb,
  p_current_index integer,
  p_elapsed_seconds integer,
  p_time_remaining_sec integer
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_block public.test_blocks;
  v_result jsonb;
  v_history public.test_history_entries;
  v_ids uuid[];
  v_keys jsonb;
  v_responses jsonb;
  v_snapshots jsonb;
  v_payload_responses jsonb;
  v_score jsonb;
  v_payload jsonb;
  v_name text;
  v_courses jsonb;
  v_profile jsonb;
  v_total integer;
  v_correct integer;
  v_answered integer;
  v_row jsonb;
  v_qid uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  -- Owner check is explicit: this function must not inherit a definer's RLS
  -- bypass when it calls the older shared write RPCs.
  select * into v_block from public.test_blocks
  where id = p_block_id and user_id = v_uid for update;
  if not found or not private.can_current_user_access_mcq() then
    raise exception 'Test not available' using errcode = '42501';
  end if;
  select result into v_result from private.test_finalizations
  where block_id = p_block_id;
  if found then return v_result; end if;

  if jsonb_typeof(p_rows) is distinct from 'array'
     or jsonb_array_length(p_rows) > 1000
     or p_current_index is null or p_current_index < 0
     or p_elapsed_seconds is null or p_elapsed_seconds < 0
     or p_time_remaining_sec < 0 then
    raise exception 'Invalid finalization request' using errcode = '22023';
  end if;
  select array_agg(question_id order by position) into v_ids
  from public.test_block_items where block_id = p_block_id;
  v_total := coalesce(cardinality(v_ids), 0);
  if v_total = 0 or v_total > 1000 then
    raise exception 'Invalid test size' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_ids) qid
    where not private.can_current_user_access_question_choice(qid)
  ) then
    raise exception 'Question not available' using errcode = '42501';
  end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_qid := (v_row->>'question_id')::uuid;
    if v_qid is null or not (v_qid = any(v_ids)) then
      raise exception 'Question is not part of this test' using errcode = '22023';
    end if;
    if v_row ? 'selected' and (
      jsonb_typeof(v_row->'selected') is distinct from 'array'
      or exists (
        select 1 from jsonb_array_elements_text(v_row->'selected') label
        where not exists (
          select 1 from public.question_choices choice
          where choice.question_id = v_qid and upper(choice.choice_label) = upper(btrim(label))
        )
      )
    ) then
      raise exception 'Invalid answer choice' using errcode = '22023';
    end if;
  end loop;

  perform public.save_test_responses(p_block_id, p_rows);
  -- Lock answered questions, including ones already saved by an older client.
  update public.test_responses set submitted = true
  where block_id = p_block_id and cardinality(selected_choice_labels) > 0;
  select * into v_block from public.save_test_block_progress(
    p_block_id, least(p_current_index, v_total - 1), p_elapsed_seconds,
    p_time_remaining_sec, 'completed'::public.app_block_status
  );

  -- Compute correctness from private answer keys, never a client payload.
  select count(*) filter (where cardinality(r.selected_choice_labels) > 0),
         count(*) filter (where cardinality(r.selected_choice_labels) > 0
           and (select array_agg(upper(label) order by upper(label))
                from unnest(r.selected_choice_labels) label) = k.correct_labels)
  into v_answered, v_correct
  from public.test_block_items i
  left join public.test_responses r using (block_id, question_id)
  left join private.answer_key_rows(v_ids) k using (question_id)
  where i.block_id = p_block_id;
  v_score := jsonb_build_object('total', v_total, 'correct', v_correct,
    'incorrect', v_answered - v_correct, 'unanswered', v_total - v_answered);
  -- Preserve the answer-reveal quota; grading does not grant extra keys.
  select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) into v_keys
  from public.get_test_answer_key(p_block_id, v_ids) k;
  select coalesce(jsonb_agg(to_jsonb(r) order by i.position), '[]'::jsonb)
  into v_responses from public.test_responses r
  join public.test_block_items i using (block_id, question_id)
  where r.block_id = p_block_id;

  select jsonb_object_agg(q.id::text, jsonb_build_object(
    'id', q.id, 'dbId', q.id, 'stem', q.stem,
    'course', c.course_name, 'topic', t.topic_name, 'status', 'published',
    'tags', '[]'::jsonb, 'author', '', 'system', c.course_name,
    'objective', coalesce(to_jsonb(q)->>'objective',''),
    'sortOrder', coalesce((to_jsonb(q)->>'sort_order')::integer,0),
    'difficulty', case to_jsonb(q)->>'difficulty' when '1' then 'Easy' when '3' then 'Hard' else 'Medium' end,
    'references', '',
    'choices', (select coalesce(jsonb_agg(jsonb_build_object('id', ch.choice_label,
       'text', ch.choice_text) order by ch.choice_label), '[]'::jsonb)
       from public.question_choices ch where ch.question_id = q.id),
    'correct', coalesce(nullif(k->'correct_labels', 'null'::jsonb), '[]'::jsonb),
    'explanation', coalesce(k->>'explanation', ''),
    'questionImage', coalesce(q.question_image_url, ''),
    'explanationImage', coalesce(k->>'explanation_image_url', '')
  )) into v_snapshots
  from public.questions q
  join public.courses c on c.id = q.course_id
  join public.course_topics t on t.id = q.topic_id
  left join jsonb_array_elements(v_keys) k on k->>'question_id' = q.id::text
  where q.id = any(v_ids);
  select jsonb_object_agg(i.question_id::text, jsonb_build_object(
    'selected', coalesce(to_jsonb(r.selected_choice_labels), '[]'::jsonb),
    'submitted', true, 'flagged', coalesce(r.flagged, false),
    'notes', coalesce(r.notes, ''), 'struck', '[]'::jsonb, 'timeSpentSec', 0
  )) into v_payload_responses
  from public.test_block_items i left join public.test_responses r using(block_id, question_id)
  where i.block_id = p_block_id;
  select coalesce(string_agg(distinct c.course_name, ', '), 'MCQ'),
    coalesce(jsonb_agg(distinct c.course_name), '[]'::jsonb) into v_name, v_courses
  from public.questions q join public.courses c on c.id = q.course_id
  where q.id = any(v_ids);
  v_name := v_name || ' • ' || initcap(v_block.mode::text) || ' • ' || v_total || ' questions';
  select to_jsonb(p) into v_profile from public.profiles p where p.id = v_uid;
  v_payload := jsonb_build_object(
    'id', p_block_id, 'testId', 'TEST-' || upper(left(p_block_id::text, 8)),
    'name', v_name, 'mode', v_block.mode, 'source', v_block.source,
    'status', 'completed', 'paused', false, 'userId', v_uid,
    'ownerIds', jsonb_build_array(v_uid), 'ownerAuthId', v_uid, 'ownerProfileId', v_uid,
    'createdAt', v_block.created_at, 'completedAt', v_block.completed_at,
    'updatedAt', v_block.completed_at, 'currentIndex', v_block.current_index,
    'durationMin', coalesce(v_block.duration_minutes, 20),
    'elapsedSec', v_block.elapsed_seconds, 'timeRemainingSec', v_block.time_remaining_sec,
    'questionCount', v_total, 'questionIds', to_jsonb(v_ids),
    'courses', v_courses, 'academicYear', v_profile->'academic_year',
    'academicSemester', v_profile->'academic_semester',
    'questionSnapshots', v_snapshots, 'responses', v_payload_responses,
    'serverScore', v_score, 'contractVersion', 1
  );
  insert into public.test_history_entries (
    user_id, external_id, course_id, session_name, session_test_id, mode, source,
    status, question_count, duration_minutes, elapsed_seconds, payload, completed_at
  ) values (
    v_uid, p_block_id::text, v_block.course_id, v_name, p_block_id::text,
    v_block.mode::text, v_block.source::text, 'completed', v_total,
    greatest(5, least(300, coalesce(v_block.duration_minutes, 20))),
    v_block.elapsed_seconds, v_payload, v_block.completed_at
  ) on conflict (user_id, external_id) do update set
    payload = excluded.payload, question_count = excluded.question_count,
    elapsed_seconds = excluded.elapsed_seconds, completed_at = excluded.completed_at,
    updated_at = now()
  returning * into v_history;
  v_result := jsonb_build_object('contract_version', 1, 'block', to_jsonb(v_block),
    'responses', v_responses, 'answer_keys', v_keys, 'score', v_score,
    'history_id', v_history.id);
  insert into private.test_finalizations(block_id, user_id, result)
  values(p_block_id, v_uid, v_result);
  return v_result;
end;
$$;
revoke all on function private.finalize_test_block(uuid,jsonb,integer,integer,integer) from public, anon;
grant execute on function private.finalize_test_block(uuid,jsonb,integer,integer,integer) to authenticated;

create function public.finalize_test_block(
  p_block_id uuid, p_rows jsonb, p_current_index integer default 0,
  p_elapsed_seconds integer default 0, p_time_remaining_sec integer default null
) returns jsonb language sql security invoker set search_path = ''
as $$ select private.finalize_test_block(p_block_id, p_rows, p_current_index,
  p_elapsed_seconds, p_time_remaining_sec); $$;
revoke all on function public.finalize_test_block(uuid,jsonb,integer,integer,integer) from public, anon;
grant execute on function public.finalize_test_block(uuid,jsonb,integer,integer,integer) to authenticated;

-- Older clients may retry their history upsert; retain the canonical result
-- rather than erroring or accepting their client-computed replacement.
create function private.preserve_finalized_test_history() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_slim jsonb;
begin
  if exists (select 1 from private.test_finalizations f
    where f.user_id = old.user_id and f.block_id::text = old.external_id) then
    -- The separately reviewed retention job may strip display text while
    -- preserving all answers, keys, scores and session metadata. Allow only
    -- that exact transformation, not a client-supplied replacement payload.
    if to_regprocedure('private.slim_question_snapshot(jsonb)') is not null
       and new.payload ? 'snapshotsSlimmedAt' then
      select coalesce(jsonb_object_agg(e.key, private.slim_question_snapshot(e.value)), '{}'::jsonb)
      into v_slim from jsonb_each(old.payload->'questionSnapshots') e;
      if (to_jsonb(new) - array['payload','updated_at']) = (to_jsonb(old) - array['payload','updated_at'])
         and new.payload - 'snapshotsSlimmedAt' = jsonb_set(
           old.payload - 'snapshotsSlimmedAt', '{questionSnapshots}', v_slim
         ) then
        return new;
      end if;
    end if;
    return old;
  end if;
  return new;
end;
$$;
revoke all on function private.preserve_finalized_test_history() from public, anon, authenticated;
create trigger preserve_finalized_test_history before update
on public.test_history_entries for each row
execute function private.preserve_finalized_test_history();

create function private.get_test_finalization(p_block_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.can_current_user_access_mcq() or not exists (
    select 1 from public.test_blocks where id = p_block_id and user_id = auth.uid()
  ) then
    raise exception 'Test not available' using errcode = '42501';
  end if;
  return (select result from private.test_finalizations where block_id = p_block_id);
end;
$$;
revoke all on function private.get_test_finalization(uuid) from public, anon;
grant execute on function private.get_test_finalization(uuid) to authenticated;
create function public.get_test_finalization(p_block_id uuid) returns jsonb
language sql stable security invoker set search_path = ''
as $$ select private.get_test_finalization(p_block_id); $$;
revoke all on function public.get_test_finalization(uuid) from public, anon;
grant execute on function public.get_test_finalization(uuid) to authenticated;
