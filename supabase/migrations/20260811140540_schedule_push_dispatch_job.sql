-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- Runs the dispatcher every minute. The secret is read from the config row
-- at call time rather than baked into the job, so rotating it does not mean
-- rewriting the schedule.
select cron.unschedule('dispatch-notification-pushes')
where exists (select 1 from cron.job where jobname = 'dispatch-notification-pushes');

select cron.schedule(
  'dispatch-notification-pushes',
  '* * * * *',
  $job$
  select net.http_post(
    url := 'https://fzjzjzdamehxbgikiskt.supabase.co/functions/v1/dispatch-notification-pushes',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select secret from private.push_dispatch_config where id)
    ),
    body := jsonb_build_object('limit', 500),
    timeout_milliseconds := 30000
  );
  $job$
);
