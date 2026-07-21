-- Fix: test_block_items.position is 1-based and contiguous (min=1). The initial
-- version used 0-based positions and violated test_block_items_position_check.
-- Reassign positions with row_number() so de-duped ids stay gap-free and 1-based.
create or replace function public.create_test_block_with_items(
  p_mode               public.app_block_mode,
  p_source             public.app_block_source,
  p_question_ids       uuid[],
  p_course_id          uuid    default null,
  p_question_count     integer default null,
  p_duration_minutes   integer default null,
  p_time_remaining_sec integer default null,
  p_current_index      integer default 0,
  p_elapsed_seconds    integer default 0,
  p_status             public.app_block_status default 'in_progress',
  p_external_id        text    default null
)
returns public.test_blocks
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_block public.test_blocks;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if p_question_ids is null or array_length(p_question_ids, 1) is null then
    raise exception 'At least one question id is required';
  end if;

  v_count := coalesce(p_question_count, array_length(p_question_ids, 1));

  if p_external_id is not null then
    insert into public.test_blocks as tb (
      user_id, course_id, mode, source, status, question_count,
      duration_minutes, time_remaining_sec, current_index, elapsed_seconds, external_id
    ) values (
      v_uid, p_course_id, p_mode, p_source, p_status, v_count,
      p_duration_minutes, p_time_remaining_sec, coalesce(p_current_index,0),
      coalesce(p_elapsed_seconds,0), p_external_id
    )
    on conflict (external_id) do update set
      course_id          = excluded.course_id,
      mode               = excluded.mode,
      source             = excluded.source,
      status             = excluded.status,
      question_count     = excluded.question_count,
      duration_minutes   = excluded.duration_minutes,
      time_remaining_sec = excluded.time_remaining_sec,
      current_index      = excluded.current_index,
      elapsed_seconds    = excluded.elapsed_seconds,
      updated_at         = now()
    where tb.user_id = v_uid
    returning * into v_block;

    if v_block.id is null then
      raise exception 'external_id already belongs to another user'
        using errcode = '42501';
    end if;

    delete from public.test_block_items where block_id = v_block.id;
  else
    insert into public.test_blocks (
      user_id, course_id, mode, source, status, question_count,
      duration_minutes, time_remaining_sec, current_index, elapsed_seconds, external_id
    ) values (
      v_uid, p_course_id, p_mode, p_source, p_status, v_count,
      p_duration_minutes, p_time_remaining_sec, coalesce(p_current_index,0),
      coalesce(p_elapsed_seconds,0), null
    )
    returning * into v_block;
  end if;

  -- 1-based, contiguous positions; de-dupe question ids, preserve first-seen order.
  insert into public.test_block_items (block_id, position, question_id)
  select v_block.id,
         row_number() over (order by d.ord)::int as position,
         d.qid
  from (
    select qid, min(ord) as ord
    from unnest(p_question_ids) with ordinality as u(qid, ord)
    group by qid
  ) d;

  return v_block;
end;
$function$;

revoke execute on function public.create_test_block_with_items(
  public.app_block_mode, public.app_block_source, uuid[], uuid, integer, integer,
  integer, integer, integer, public.app_block_status, text) from anon;
;
