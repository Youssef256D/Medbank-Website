-- One device per student account.
--
-- The first app installation a student signs in on claims the account; any
-- other installation is refused until an admin releases the device. Admins
-- and creators are never limited.
--
-- One row per account is the limit itself: the primary key on user_id is what
-- makes "the first device wins" atomic, so two phones signing in at the same
-- moment cannot both register.
--
-- device_id is a random per-installation id the app keeps in the Keychain /
-- Keystore. It is not a hardware identifier and says nothing about the phone.

create table public.user_devices (
  user_id uuid primary key references auth.users (id) on delete cascade,
  device_id text not null check (char_length(device_id) between 8 and 128),
  device_name text not null default '' check (char_length(device_name) <= 120),
  platform text not null default '' check (char_length(platform) <= 32),
  registered_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

comment on table public.user_devices is
  'The one app installation each student account is bound to. Written only by claim_user_device; admins read and delete (delete = release the device).';

alter table public.user_devices enable row level security;

revoke all on public.user_devices from anon, authenticated;
grant select, delete on public.user_devices to authenticated;

-- Students get no direct access at all: the RPCs below are their only door,
-- and they never reveal the stored device id.
create policy "Admins read registered devices"
  on public.user_devices for select to authenticated
  using ((select private.is_admin_user()));

create policy "Admins release registered devices"
  on public.user_devices for delete to authenticated
  using ((select private.is_admin_user()));

create or replace function private.user_device_gate(
  p_device_id text,
  p_device_name text,
  p_platform text,
  p_claim boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.app_user_role;
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_name text := left(btrim(coalesce(p_device_name, '')), 120);
  v_platform text := left(btrim(coalesce(p_platform, '')), 32);
  v_row public.user_devices%rowtype;
  c_limit constant integer := 1;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if char_length(v_device_id) not between 8 and 128 then
    raise exception 'invalid_device_id' using errcode = '22023';
  end if;

  select p.role into v_role from public.profiles p where p.id = v_uid;
  if v_role in ('admin', 'creator') then
    return jsonb_build_object(
      'status', 'allowed',
      'devices_used', 0,
      'device_limit', null
    );
  end if;

  if p_claim then
    insert into public.user_devices (user_id, device_id, device_name, platform)
    values (v_uid, v_device_id, v_name, v_platform)
    on conflict (user_id) do nothing;
  end if;

  select * into v_row from public.user_devices d where d.user_id = v_uid;

  -- No registration while checking: an admin released this account's device
  -- since the app last claimed it.
  if not found then
    return jsonb_build_object(
      'status', 'revoked',
      'devices_used', 0,
      'device_limit', c_limit
    );
  end if;

  if v_row.device_id = v_device_id then
    -- The app checks every 30 seconds; a write each time buys nothing.
    if v_row.last_seen_at < now() - interval '5 minutes'
       or (v_name <> '' and v_row.device_name is distinct from v_name) then
      update public.user_devices
         set last_seen_at = now(),
             device_name = case when v_name <> '' then v_name else device_name end,
             platform = case when v_platform <> '' then v_platform else platform end
       where user_id = v_uid;
    end if;
    return jsonb_build_object(
      'status', 'allowed',
      'devices_used', 1,
      'device_limit', c_limit
    );
  end if;

  return jsonb_build_object(
    'status', 'another_device_active',
    'active_device_name', nullif(v_row.device_name, ''),
    'active_device_platform', nullif(v_row.platform, ''),
    'registered_at', v_row.registered_at,
    'devices_used', 1,
    'device_limit', c_limit
  );
end;
$$;

revoke all on function private.user_device_gate(text, text, text, boolean) from public;

-- Registers this installation if the account has none, then reports whether
-- it is the registered one. Called once per app session.
create or replace function public.claim_user_device(
  p_device_id text,
  p_device_name text default null,
  p_platform text default null
)
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select private.user_device_gate(p_device_id, p_device_name, p_platform, true);
$$;

-- Reports whether this installation is still the registered one, without
-- registering anything. Polled while the app is open.
create or replace function public.check_user_device(
  p_device_id text,
  p_device_name text default null,
  p_platform text default null
)
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select private.user_device_gate(p_device_id, p_device_name, p_platform, false);
$$;

revoke all on function public.claim_user_device(text, text, text) from public, anon;
revoke all on function public.check_user_device(text, text, text) from public, anon;
grant execute on function public.claim_user_device(text, text, text) to authenticated;
grant execute on function public.check_user_device(text, text, text) to authenticated;
