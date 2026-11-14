-- User-requested rollback of the additive 20261111020211 contract.
-- Abort rather than delete any canonical result created before this executes.
-- Existing attempts, answers, history and legacy RPCs are untouched.
do $rollback$
begin
  lock table private.test_finalizations in access exclusive mode;
  if exists (select 1 from private.test_finalizations) then
    raise exception 'Rollback refused: preserve canonical test results before removing this table';
  end if;
  drop trigger preserve_finalized_test_history on public.test_history_entries;
  drop function public.finalize_test_block(uuid,jsonb,integer,integer,integer);
  drop function public.get_test_finalization(uuid);
  drop function private.finalize_test_block(uuid,jsonb,integer,integer,integer);
  drop function private.get_test_finalization(uuid);
  drop function private.preserve_finalized_test_history();
  drop table private.test_finalizations;
end;
$rollback$;
