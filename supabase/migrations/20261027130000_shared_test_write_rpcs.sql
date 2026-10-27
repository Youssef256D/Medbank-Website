-- Shared tests: one set of write rules for the website and the app.
--
-- The website (main.js syncLiveTestBlocks) and the app
-- (Medbank-App lib/features/tests) both write test_responses and
-- test_blocks for the same unfinished test. Until now each client carried
-- its own copy of the merge rules, the copies drifted, and every drift was a
-- lost or reopened answer (website PRs #45-#52). The rules now live here:
--
--   save_test_responses(block, rows)   answers, flags and notes
--   save_test_block_progress(block, …) index, clock, status
--
-- Both are security invoker, so RLS (owner + MCQ access) still decides who
-- may write. Old app builds and stale tabs keep writing the tables directly
-- for a while, so the two rules that must hold against them are also in
-- BEFORE triggers: a solved answer stays solved (test_responses) and a
-- completed block stays completed (test_blocks).
--
-- Answer rules, per row, in order (save_test_responses):
--   1. the question must be an item of the block, else the row is skipped;
--   2. on a completed block the answer is frozen (flag and notes still save);
--   3. a missing or empty `selected` leaves the answer as stored;
--   4. a solved answer (selection + submitted) is never changed;
--   5. `expected` (optional) is a compare-and-set for an unsubmitted pick:
--      when the stored selection is not empty and differs from it, the
--      answer is left as stored (the other device changed it; the caller
--      takes the returned row). A submitted answer skips this check: a solve
--      on either device beats an unsubmitted pick on the other;
--   6. otherwise selection, submitted (only with a selection) and
--      answered_at are written.
-- A key left out of a row means "keep what is stored" (flagged, notes too).
-- The stored rows are returned after the merge.
--
-- Progress rules (save_test_block_progress):
--   * completed is final; completed_at is set once;
--   * in_progress <-> suspended while not completed;
--   * current_index: last write wins (it counts the questions the app can
--     show; the website translates through question ids);
--   * elapsed_seconds only grows, time_remaining_sec only shrinks, so a
--     device with an older clock can't wind the timer back.
-- Nothing is written when nothing changes, so updated_at (which the website
-- watches to pull changes) only moves on a real change.

-- 1. Triggers --------------------------------------------------------------

-- Same body as 20261027120000_server_side_grading (server-side grading
-- session): keep the two identical so either order of applying agrees.
create or replace function private.protect_test_response_answer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- once stored solved (selection + submitted), an update keeps the old
  -- selection, submitted and answered_at (flag and notes still update)
  if tg_op = 'UPDATE'
     and old.submitted
     and coalesce(cardinality(old.selected_choice_labels), 0) > 0 then
    new.selected_choice_labels := old.selected_choice_labels;
    new.submitted := true;
    new.answered_at := old.answered_at;
  end if;

  if tg_op = 'UPDATE'
     and coalesce(cardinality(new.selected_choice_labels), 0) = 0
     and coalesce(cardinality(old.selected_choice_labels), 0) > 0 then
    new.selected_choice_labels := old.selected_choice_labels;
    new.submitted := old.submitted;
    new.answered_at := old.answered_at;
  end if;

  if coalesce(cardinality(new.selected_choice_labels), 0) = 0 then
    new.submitted := false;
  end if;

  return new;
end;
$$;

create or replace function private.protect_completed_test_block()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.status = 'completed' then
    new.status := 'completed';
    new.completed_at := coalesce(old.completed_at, new.completed_at);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_completed_test_block on public.test_blocks;
create trigger trg_protect_completed_test_block
  before update on public.test_blocks
  for each row execute function private.protect_completed_test_block();

-- 2. save_test_responses ---------------------------------------------------

create or replace function private.test_response_labels(p_value jsonb)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(l.label order by l.ord), '{}'::text[])
  from (
    select upper(btrim(e.value)) as label, min(e.ord) as ord
    from jsonb_array_elements_text(
      case when jsonb_typeof(p_value) = 'array' then p_value else '[]'::jsonb end
    ) with ordinality as e(value, ord)
    where upper(btrim(e.value)) ~ '^[A-E]$'
    group by 1
  ) l;
$$;

create or replace function public.save_test_responses(
  p_block_id uuid,
  p_rows     jsonb
)
returns setof public.test_responses
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_block      public.test_blocks;
  v_row        jsonb;
  v_qid        uuid;
  v_old        public.test_responses;
  v_new        public.test_responses;
  v_selected   text[];
  v_expected   text[];
  v_write      boolean;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array' using errcode = '22023';
  end if;

  -- Locks the block, so two saves for one test run one after the other.
  select * into v_block from public.test_blocks where id = p_block_id for update;
  if not found then
    raise exception 'Test not found' using errcode = 'P0002';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_qid := nullif(btrim(coalesce(v_row->>'question_id', '')), '')::uuid;
    if v_qid is null or not exists (
      select 1 from public.test_block_items i
      where i.block_id = p_block_id and i.question_id = v_qid
    ) then
      continue;
    end if;

    insert into public.test_responses (block_id, question_id)
    values (p_block_id, v_qid)
    on conflict (block_id, question_id) do nothing;

    select * into v_old from public.test_responses
    where block_id = p_block_id and question_id = v_qid
    for update;

    v_new := v_old;
    v_selected := private.test_response_labels(v_row->'selected');
    v_write := v_block.status <> 'completed'
      and cardinality(v_selected) > 0
      and not (v_old.submitted and cardinality(v_old.selected_choice_labels) > 0);
    if v_write and v_row ? 'expected'
       and not coalesce((v_row->>'submitted')::boolean, false)
       and cardinality(v_old.selected_choice_labels) > 0 then
      v_expected := private.test_response_labels(v_row->'expected');
      v_write := v_expected = v_old.selected_choice_labels;
    end if;
    if v_write then
      v_new.selected_choice_labels := v_selected;
      v_new.submitted := coalesce((v_row->>'submitted')::boolean, false);
      v_new.answered_at := coalesce((v_row->>'answered_at')::timestamptz, now());
    end if;

    if v_row ? 'flagged' then
      v_new.flagged := coalesce((v_row->>'flagged')::boolean, false);
    end if;
    if v_row ? 'notes' then
      v_new.notes := v_row->>'notes';
    end if;

    if v_new is distinct from v_old then
      update public.test_responses
      set selected_choice_labels = v_new.selected_choice_labels,
          submitted = v_new.submitted,
          answered_at = v_new.answered_at,
          flagged = v_new.flagged,
          notes = v_new.notes
      where block_id = p_block_id and question_id = v_qid
      returning * into v_new;
    end if;

    return next v_new;
  end loop;
end;
$$;

-- 3. save_test_block_progress ----------------------------------------------

create or replace function public.save_test_block_progress(
  p_block_id           uuid,
  p_current_index      integer default null,
  p_elapsed_seconds    integer default null,
  p_time_remaining_sec integer default null,
  p_status             public.app_block_status default null,
  p_completed_at       timestamptz default null
)
returns public.test_blocks
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_old    public.test_blocks;
  v_new    public.test_blocks;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select * into v_old from public.test_blocks where id = p_block_id for update;
  if not found then
    raise exception 'Test not found' using errcode = 'P0002';
  end if;
  if v_old.status = 'completed' then
    return v_old;
  end if;

  v_new := v_old;
  if p_current_index is not null then
    v_new.current_index := greatest(0, p_current_index);
  end if;
  if p_elapsed_seconds is not null then
    v_new.elapsed_seconds := greatest(v_old.elapsed_seconds, p_elapsed_seconds);
  end if;
  if p_time_remaining_sec is not null then
    v_new.time_remaining_sec := case
      when v_old.time_remaining_sec is null then greatest(0, p_time_remaining_sec)
      else least(v_old.time_remaining_sec, greatest(0, p_time_remaining_sec))
    end;
  end if;
  if p_status is not null then
    v_new.status := p_status;
    if p_status = 'completed' then
      v_new.completed_at := coalesce(v_old.completed_at, p_completed_at, now());
    end if;
  end if;

  if v_new is distinct from v_old then
    update public.test_blocks
    set current_index = v_new.current_index,
        elapsed_seconds = v_new.elapsed_seconds,
        time_remaining_sec = v_new.time_remaining_sec,
        status = v_new.status,
        completed_at = v_new.completed_at
    where id = p_block_id
    returning * into v_new;
  end if;

  return v_new;
end;
$$;

grant execute on function private.test_response_labels(jsonb) to authenticated;
revoke execute on function public.save_test_responses(uuid, jsonb) from public, anon;
grant execute on function public.save_test_responses(uuid, jsonb) to authenticated;
revoke execute on function public.save_test_block_progress(uuid, integer, integer, integer, public.app_block_status, timestamptz) from public, anon;
grant execute on function public.save_test_block_progress(uuid, integer, integer, integer, public.app_block_status, timestamptz) to authenticated;
