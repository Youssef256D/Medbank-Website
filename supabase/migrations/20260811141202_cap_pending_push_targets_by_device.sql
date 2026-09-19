-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- p_limit must bound the *sends*, not the notifications.
--
-- One broadcast is one notification and as many targets as there are devices.
-- Limiting the notifications left the returned pair count unbounded, so a
-- broadcast to a large audience would hand a single run thousands of FCM
-- calls. Deliveries are only recorded once every send has finished, so a run
-- that ran out of time would leave no record and the next minute would send
-- the whole batch again — to phones that had already buzzed.
--
-- Bounded per device, a broadcast drains across successive runs instead, each
-- one recording what it sent.
create or replace function public.pending_push_targets(
  p_limit integer default 500
)
returns table (
  notification_id uuid,
  title text,
  message text,
  target_route text,
  target_mcq_subject text,
  target_mcq_topic text,
  target_video_course_id uuid,
  push_token_id uuid,
  token text,
  platform text
)
language sql
security definer
set search_path to ''
as $$
  with config as (
    select enabled, max_age from private.push_dispatch_config where id
  ),
  recent as (
    select n.*
    from public.notifications n, config c
    where c.enabled
      and n.is_active
      and n.created_at > now() - c.max_age
  ),
  audience as (
    select r.id as notification_id, p.id as user_id
    from recent r
    join public.profiles p on
      case
        when r.recipient_user_id is not null then p.id = r.recipient_user_id
        when r.external_id ~* '^year[1-5]::' then
          p.role::text = 'student'
          and p.approved
          and p.academic_year = substring(r.external_id from 5 for 1)::smallint
        else p.created_at <= r.created_at
      end
  )
  select
    r.id,
    r.title,
    r.message,
    r.target_route,
    r.target_mcq_subject,
    r.target_mcq_topic,
    r.target_video_course_id,
    t.id,
    t.token,
    t.platform
  from recent r
  join audience a on a.notification_id = r.id
  join public.push_device_tokens t on t.user_id = a.user_id
  where t.updated_at > now() - interval '120 days'
    and not exists (
      select 1
      from public.push_notification_deliveries d
      where d.notification_id = r.id
        and d.push_token_id = t.id
        and d.status = 'sent'
    )
  -- Oldest first, so a large broadcast cannot starve the announcement behind
  -- it indefinitely.
  order by r.created_at, t.id
  limit greatest(p_limit, 0);
$$;

revoke all on function public.pending_push_targets(integer) from public, anon, authenticated;
grant execute on function public.pending_push_targets(integer) to service_role;
