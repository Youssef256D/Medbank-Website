-- Rollback for 20261027130000_shared_test_write_rpcs.sql: drops the two
-- shared-test RPCs and the completed-block guard, and puts the answer guard
-- back to its 2026-10-25 body (20261025200000_protect_test_response_answers).
-- If 20261027140000_server_side_grading is applied, it needs the
-- "solved stays solved" trigger rule: skip the protect_test_response_answer
-- part below (keep the function as it is) in that case.
-- Clients on the RPCs fall back to direct table writes when the functions
-- are missing (PGRST202), so this is safe to run while they are live.

drop function if exists public.save_test_responses(uuid, jsonb);
drop function if exists public.save_test_block_progress(uuid, integer, integer, integer, public.app_block_status, timestamptz);
drop function if exists private.test_response_labels(jsonb);

drop trigger if exists trg_protect_completed_test_block on public.test_blocks;
drop function if exists private.protect_completed_test_block();

create or replace function private.protect_test_response_answer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
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
