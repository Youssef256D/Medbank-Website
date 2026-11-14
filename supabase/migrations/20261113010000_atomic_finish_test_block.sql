-- Finishes a test block in one atomic transaction:
-- 1. Saves all submitted responses via `save_test_responses`
-- 2. Marks the block completed via `save_test_block_progress`
-- 3. Grades the block's questions via `get_test_answer_key`
-- 4. Upserts the graded `test_history_entries` archive row (idempotent on
--    `(user_id, external_id)`)
-- 5. Returns the stored responses and revealed answer keys in one round-trip.

create or replace function public.finish_test_block(
  p_block_id uuid,
  p_rows jsonb,
  p_question_ids uuid[],
  p_current_index integer,
  p_elapsed_seconds integer,
  p_time_remaining_sec integer default null,
  p_session_name text default null,
  p_duration_minutes integer default null,
  p_history_payload jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_block public.test_blocks%rowtype;
  v_responses jsonb := '[]'::jsonb;
  v_keys jsonb := '[]'::jsonb;
  v_payload jsonb := p_history_payload;
  v_snapshots jsonb;
  v_resp_map jsonb;
  v_key record;
  v_resp record;
  v_qid text;
  v_snap jsonb;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select *
    into v_block
    from public.test_blocks
   where id = p_block_id
     and user_id = v_user_id
   for update;

  if not found then
    raise exception 'Test block not found' using errcode = 'P0002';
  end if;

  -- 1. Persist all response rows atomically using the shared merge rules.
  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
    into v_responses
    from public.save_test_responses(p_block_id, coalesce(p_rows, '[]'::jsonb)) as r;

  -- 2. Mark the block completed with monotonic elapsed/remaining rules.
  perform public.save_test_block_progress(
    p_block_id => p_block_id,
    p_current_index => p_current_index,
    p_elapsed_seconds => p_elapsed_seconds,
    p_time_remaining_sec => p_time_remaining_sec,
    p_status => 'completed'::public.app_block_status
  );

  -- 3. Reveal keys for the completed block.
  select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb)
    into v_keys
    from public.get_test_answer_key(p_block_id, p_question_ids) as k;

  -- 4. Archive to test_history_entries in the same transaction when a payload
  --    template is supplied, patching in the canonical stored responses and
  --    server-revealed answer keys.
  if v_payload is not null then
    v_snapshots := coalesce(v_payload->'questionSnapshots', '{}'::jsonb);
    v_resp_map := coalesce(v_payload->'responses', '{}'::jsonb);

    for v_resp in
      select * from jsonb_to_recordset(v_responses) as x(
        question_id uuid,
        selected_choice_labels text[],
        flagged boolean,
        notes text
      )
    loop
      v_qid := v_resp.question_id::text;
      v_resp_map := jsonb_set(
        v_resp_map,
        array[v_qid],
        jsonb_build_object(
          'notes', coalesce(v_resp.notes, ''),
          'struck', '[]'::jsonb,
          'flagged', coalesce(v_resp.flagged, false),
          'selected', to_jsonb(coalesce(v_resp.selected_choice_labels, array[]::text[])),
          'submitted', true,
          'timeSpentSec', 0
        ),
        true
      );
    end loop;

    for v_key in
      select * from jsonb_to_recordset(v_keys) as x(
        question_id uuid,
        correct_labels text[],
        explanation text,
        explanation_image_url text,
        capped boolean
      )
    loop
      v_qid := v_key.question_id::text;
      if v_snapshots ? v_qid and coalesce(array_length(v_key.correct_labels, 1), 0) > 0 then
        v_snap := v_snapshots->v_qid;
        v_snap := jsonb_set(v_snap, '{correct}', to_jsonb(v_key.correct_labels), true);
        v_snap := jsonb_set(v_snap, '{explanation}', to_jsonb(coalesce(v_key.explanation, '')), true);
        v_snap := jsonb_set(
          v_snap,
          '{explanationImage}',
          to_jsonb(coalesce(v_key.explanation_image_url, '')),
          true
        );
        v_snapshots := jsonb_set(v_snapshots, array[v_qid], v_snap, true);
      end if;
    end loop;

    v_payload := jsonb_set(v_payload, '{questionSnapshots}', v_snapshots, true);
    v_payload := jsonb_set(v_payload, '{responses}', v_resp_map, true);

    insert into public.test_history_entries (
      user_id,
      external_id,
      course_id,
      session_name,
      session_test_id,
      mode,
      source,
      status,
      question_count,
      duration_minutes,
      elapsed_seconds,
      payload,
      completed_at
    )
    values (
      v_user_id,
      p_block_id::text,
      v_block.course_id,
      coalesce(p_session_name, 'Test'),
      p_block_id::text,
      v_block.mode::text,
      coalesce(v_block.source::text, 'all'),
      'completed',
      coalesce(array_length(p_question_ids, 1), v_block.question_count),
      least(
        300,
        greatest(
          5,
          coalesce(
            p_duration_minutes,
            v_block.duration_minutes,
            ceil(greatest(p_elapsed_seconds, 1)::numeric / 60.0)::integer
          )
        )
      ),
      greatest(v_block.elapsed_seconds, coalesce(p_elapsed_seconds, 0)),
      v_payload,
      now()
    )
    on conflict (user_id, external_id) do update
      set session_name = excluded.session_name,
          status = 'completed',
          question_count = excluded.question_count,
          duration_minutes = excluded.duration_minutes,
          elapsed_seconds = greatest(public.test_history_entries.elapsed_seconds, excluded.elapsed_seconds),
          payload = excluded.payload,
          updated_at = now();
  end if;

  return jsonb_build_object(
    'responses', v_responses,
    'keys', v_keys
  );
end;
$$;

comment on function public.finish_test_block(
  uuid, jsonb, uuid[], integer, integer, integer, text, integer, jsonb
) is
  'Atomically saves all responses, marks the test block completed, grades answers, and archives the test history entry.';

revoke all on function public.finish_test_block(
  uuid, jsonb, uuid[], integer, integer, integer, text, integer, jsonb
) from public, anon;

grant execute on function public.finish_test_block(
  uuid, jsonb, uuid[], integer, integer, integer, text, integer, jsonb
) to authenticated;

-- Collapses the 7 startup/tab-entry reads of the Video Courses surface into a
-- single round-trip while preserving caller RLS (`security invoker`).
create or replace function public.get_my_video_courses_dashboard()
returns jsonb
language sql
security invoker
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'courses', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.course_name)
      from (
        select id, course_code, course_name, description, cover_image_url,
               intro_video_url, instructor_name, instructor_bio, level,
               estimated_duration, enrollment_mode, price, spoken_watermark_enabled
        from public.platform_courses
        where is_active = true
      ) c
    ), '[]'::jsonb),
    'enrollments', coalesce((
      select jsonb_agg(to_jsonb(e))
      from (
        select user_id, course_id, assigned_at
        from public.platform_course_enrollments
        where user_id = (select auth.uid())
      ) e
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(to_jsonb(d))
      from public.get_my_course_devices() d
    ), '[]'::jsonb),
    'access', coalesce((
      select jsonb_agg(to_jsonb(a))
      from public.get_my_platform_course_access() a
    ), '[]'::jsonb),
    'progress', coalesce((
      select jsonb_agg(to_jsonb(p))
      from (
        select id, user_id, course_id, lesson_id, status, progress_percent,
               watched_seconds, completed_at
        from public.platform_lesson_progress
        where user_id = (select auth.uid())
      ) p
    ), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at desc)
      from (
        select id, user_id, course_id, status, created_at
        from public.platform_course_enrollment_requests
        where user_id = (select auth.uid())
      ) r
    ), '[]'::jsonb),
    'announcements', coalesce((
      select jsonb_agg(to_jsonb(ann) order by ann.created_at desc)
      from (
        select id, course_id, title, body, created_at
        from public.platform_course_announcements
      ) ann
    ), '[]'::jsonb)
  );
$$;

comment on function public.get_my_video_courses_dashboard() is
  'Returns visible courses, enrollments, device placements, course access, lesson progress, enrollment requests, and announcements in one round-trip.';

revoke all on function public.get_my_video_courses_dashboard() from public, anon;
grant execute on function public.get_my_video_courses_dashboard() to authenticated;
