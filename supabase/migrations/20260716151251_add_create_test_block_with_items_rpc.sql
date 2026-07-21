-- BUG 2a: Phantom test_blocks (block row created, items insert never lands).
-- Root cause is a non-atomic multi-step client write. This RPC performs the
-- block insert + item inserts + initial state in ONE transaction (a function
-- body is atomic), so either everything commits or nothing does.
--
-- SECURITY INVOKER: runs with the CALLER's privileges, so the existing RLS on
-- test_blocks / test_block_items enforces ownership unchanged:
--   blocks_insert : user_id = auth.uid() AND private.can_current_user_access_mcq()
--   items_insert  : parent block owned by auth.uid()
-- No RLS is added, weakened, or bypassed.
--
-- Idempotent on external_id so a client retry after a partial/failed attempt
-- reconciles instead of orphaning a new row (safe for the mobile app too).

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
    where tb.user_id = v_uid            -- never adopt another user's row
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

  -- Items are inserted atomically with the block; de-dupe ids, preserve order.
  insert into public.test_block_items (block_id, position, question_id)
  select v_block.id, ord - 1, qid
  from (
    select qid, min(ord) as ord
    from unnest(p_question_ids) with ordinality as u(qid, ord)
    group by qid
  ) d
  order by d.ord;

  return v_block;
end;
$function$;

revoke all on function public.create_test_block_with_items(
  public.app_block_mode, public.app_block_source, uuid[], uuid, integer, integer,
  integer, integer, integer, public.app_block_status, text
) from public;
grant execute on function public.create_test_block_with_items(
  public.app_block_mode, public.app_block_source, uuid[], uuid, integer, integer,
  integer, integer, integer, public.app_block_status, text
) to authenticated;
;
