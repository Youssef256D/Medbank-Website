-- BUG 1: Test results must be permanent.
-- The retention trigger silently dropped inserts with completed_at older than
-- 20 days (returned NULL), and a daily pg_cron job pruned old rows. Both are
-- removed here. Table shape / constraints / unique indexes are untouched.

-- 1) Stop the daily pruning job (cron.job id 1: "17 2 * * *").
--    Unschedule by the exact command so this is stable even if the id changes.
do $$
declare
  v_jobid bigint;
begin
  for v_jobid in
    select jobid from cron.job
    where command ilike '%delete_old_test_history_entries%'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
end;
$$;

-- 2) Remove the write-time retention trigger + its function so backdated
--    inserts/updates are no longer silently discarded.
drop trigger if exists trg_test_history_entries_retention_window on public.test_history_entries;
drop function if exists public.enforce_test_history_retention_window();

-- NOTE: public.delete_old_test_history_entries(int) is intentionally KEPT but
-- is now unscheduled. It is harmless while never invoked and is available for
-- an explicit, manual payload-compaction step later (per owner request, any
-- such compaction will be proposed before use). It is not called anywhere.
;
