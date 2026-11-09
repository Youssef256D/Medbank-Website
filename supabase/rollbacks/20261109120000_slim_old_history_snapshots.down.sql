-- Stops further slimming. Rows already slimmed stay slim: the dropped
-- question text cannot be restored from the database (restore from a backup;
-- see docs/backup-restore-runbook.md).
select cron.unschedule('slim-old-history-snapshots')
where exists (select 1 from cron.job where jobname = 'slim-old-history-snapshots');

drop procedure if exists private.run_history_slimming(integer, integer, interval);
drop function if exists private.slim_question_snapshot(jsonb);
