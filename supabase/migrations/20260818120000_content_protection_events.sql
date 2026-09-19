-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- Audio-side content protection telemetry.
--
-- The app cannot stop a microphone — no mobile OS lets one app silence
-- another's recorder, and none can see a second phone on the desk. The spoken
-- identity watermark is what makes a leaked recording attributable; this table
-- is the weaker, secondary signal: the moments a lesson was interrupted by
-- another app taking the audio session while a student was watching.
--
-- Treat a row as a hint, never as proof. An incoming call, an alarm, and a
-- voice note all produce the same signal, and on Android many recorders
-- produce none at all. The value is in the pattern per account over time.

create table if not exists public.content_protection_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('microphone_contention')),
  platform text not null check (platform in ('android', 'ios', 'other')),
  -- Plain text, no foreign key. These identify *where* a signal happened for
  -- an admin reading a list; they are not a relationship worth enforcing, and
  -- a deleted lesson must not take the record of an event with it.
  lesson_id text,
  video_course_id text,
  occurred_at timestamptz not null default now()
);

-- The admin view reads "recent events, newest first", per account and overall.
create index if not exists content_protection_events_occurred_at_idx
  on public.content_protection_events (occurred_at desc);

create index if not exists content_protection_events_user_idx
  on public.content_protection_events (user_id, occurred_at desc);

alter table public.content_protection_events enable row level security;

-- A student may report their own events and nothing else. They deliberately
-- cannot read them back: this is a record about the account, not a feature of
-- it, and a client that can enumerate its own flags can tune around them.
drop policy if exists content_protection_events_insert_own
  on public.content_protection_events;

create policy content_protection_events_insert_own
  on public.content_protection_events
  for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists content_protection_events_admin_read
  on public.content_protection_events;

create policy content_protection_events_admin_read
  on public.content_protection_events
  for select
  to authenticated
  using (private.is_admin_user());

grant insert on public.content_protection_events to authenticated;

grant select on public.content_protection_events to authenticated;
