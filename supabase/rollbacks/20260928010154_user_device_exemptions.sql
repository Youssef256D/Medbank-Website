-- Rollback for 20260928010154_user_device_exemptions.sql:
-- restores the gate exactly as shipped in 20260927145744, then drops the table.

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

drop table if exists public.user_device_exemptions;
