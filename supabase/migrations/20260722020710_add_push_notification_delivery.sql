-- Native FCM token registration and idempotent per-device delivery tracking.

create schema if not exists private;
revoke all on schema private from public;

create table if not exists public.push_device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null check (platform in ('android', 'ios')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_device_tokens_token_not_blank check (btrim(token) <> ''),
  constraint push_device_tokens_token_length check (char_length(token) <= 4096)
);

create index if not exists idx_push_device_tokens_user_id
  on public.push_device_tokens (user_id);
create index if not exists idx_push_device_tokens_updated_at
  on public.push_device_tokens (updated_at desc);

alter table public.push_device_tokens enable row level security;
revoke all on table public.push_device_tokens from anon, authenticated;
grant select, insert, update, delete on table public.push_device_tokens to service_role;

create table if not exists public.push_notification_deliveries (
  notification_id uuid not null references public.notifications(id) on delete cascade,
  push_token_id uuid not null references public.push_device_tokens(id) on delete cascade,
  status text not null check (status in ('sent', 'failed')),
  provider_message_id text,
  last_error text,
  last_attempt_at timestamptz not null default now(),
  primary key (notification_id, push_token_id)
);

create index if not exists idx_push_notification_deliveries_status
  on public.push_notification_deliveries (status, last_attempt_at desc);

alter table public.push_notification_deliveries enable row level security;
revoke all on table public.push_notification_deliveries from anon, authenticated;
grant select, insert, update, delete on table public.push_notification_deliveries to service_role;

create or replace function private.register_push_token(
  p_token text,
  p_platform text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  clean_token text := btrim(coalesce(p_token, ''));
  clean_platform text := lower(btrim(coalesce(p_platform, '')));
  registered_id uuid;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if clean_token = '' or char_length(clean_token) > 4096 then
    raise exception 'Invalid push token';
  end if;
  if clean_platform not in ('android', 'ios') then
    raise exception 'Invalid push platform';
  end if;

  insert into public.push_device_tokens (user_id, token, platform)
  values (caller_id, clean_token, clean_platform)
  on conflict (token) do update
  set user_id = excluded.user_id,
      platform = excluded.platform,
      updated_at = now()
  returning id into registered_id;

  return registered_id;
end;
$$;

create or replace function private.unregister_push_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  delete from public.push_device_tokens
  where user_id = auth.uid()
    and token = btrim(coalesce(p_token, ''));
  get diagnostics deleted_count = row_count;
  return deleted_count > 0;
end;
$$;

revoke all on function private.register_push_token(text, text) from public;
revoke all on function private.unregister_push_token(text) from public;
grant usage on schema private to authenticated;
grant execute on function private.register_push_token(text, text) to authenticated;
grant execute on function private.unregister_push_token(text) to authenticated;

create or replace function public.register_push_token(
  p_token text,
  p_platform text
)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select private.register_push_token(p_token, p_platform);
$$;

create or replace function public.unregister_push_token(p_token text)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select private.unregister_push_token(p_token);
$$;

revoke all on function public.register_push_token(text, text) from public, anon;
revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;
grant execute on function public.unregister_push_token(text) to authenticated;

comment on table public.push_device_tokens is
  'Native Firebase Cloud Messaging registration tokens, one row per app installation token.';
comment on table public.push_notification_deliveries is
  'Idempotency and retry state for per-device FCM notification delivery.';
