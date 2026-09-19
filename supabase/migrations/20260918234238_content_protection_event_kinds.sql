-- Recovered from the hosted migration ledger (supabase_migrations.schema_migrations)
-- on 2026-09-20: this was applied to the hosted project but never committed.
-- Contents are byte-for-byte what the hosted project recorded.

alter table public.content_protection_events
  drop constraint if exists content_protection_events_kind_check;

alter table public.content_protection_events
  add constraint content_protection_events_kind_check
  check (kind in (
    'microphone_contention',
    'unattributed_playback',
    'speech_failure',
    'screenshot_captured'
  ));
