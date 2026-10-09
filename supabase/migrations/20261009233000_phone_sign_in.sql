-- Sign in with the phone number on the profile and the account's usual
-- password.
--
-- Supabase Auth only signs in by phone when the phone is on auth.users and
-- the SMS provider is set up; ours lives on profiles.phone. So the
-- `sign-in-with-phone` Edge Function does the lookup: it asks
-- phone_sign_in_candidates() for the accounts behind a number, compares the
-- password against their bcrypt hashes itself (the password never reaches
-- Postgres, where a failed statement could log it), and signs the one match
-- in with a one-time token. The email address never leaves the server, so a
-- phone number cannot be used to look one up.
--
-- Both functions are for the service role only.

-- One spelling per number: digits only, international, no leading 00 or +.
-- An Egyptian national number (01xxxxxxxxx) and "+20 0..." mean +20 1....
create or replace function private.phone_sign_in_key(raw_phone text)
returns text
language plpgsql
immutable
set search_path to ''
as $function$
declare
  digits text := regexp_replace(coalesce(raw_phone, ''), '[^0-9]', '', 'g');
begin
  if left(digits, 2) = '00' then
    digits := substr(digits, 3);
  end if;
  if digits ~ '^01[0-9]{9}$' then
    digits := '20' || substr(digits, 2);
  elsif digits ~ '^2001[0-9]{9}$' then
    digits := '20' || substr(digits, 4);
  end if;
  if length(digits) < 8 or length(digits) > 15 then
    return null;
  end if;
  return digits;
end;
$function$;

create index if not exists profiles_phone_sign_in_key_idx
  on public.profiles (private.phone_sign_in_key(phone))
  where phone is not null;

-- Failed tries per number. Ten in fifteen minutes and the number is refused
-- until the window passes, whatever the password.
create table if not exists private.phone_sign_in_failures (
  id bigint generated always as identity primary key,
  phone_key text not null,
  failed_at timestamptz not null default now()
);
create index if not exists phone_sign_in_failures_key_idx
  on private.phone_sign_in_failures (phone_key, failed_at);

create or replace function public.phone_sign_in_candidates(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  key text := private.phone_sign_in_key(p_phone);
  recent integer;
begin
  if key is null then
    return jsonb_build_object('throttled', false, 'candidates', '[]'::jsonb);
  end if;

  delete from private.phone_sign_in_failures
  where failed_at < now() - interval '1 day';

  select count(*) into recent
  from private.phone_sign_in_failures f
  where f.phone_key = key
    and f.failed_at > now() - interval '15 minutes';
  if recent >= 10 then
    return jsonb_build_object('throttled', true, 'candidates', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'throttled', false,
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'email', u.email,
        'password_hash', u.encrypted_password,
        'email_confirmed', u.email_confirmed_at is not null,
        'banned', coalesce(u.banned_until > now(), false)
      ))
      from public.profiles p
      join auth.users u on u.id = p.id
      where private.phone_sign_in_key(p.phone) = key
        and coalesce(u.encrypted_password, '') <> ''
        and coalesce(u.email, '') <> ''
        and u.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$function$;

create or replace function public.record_phone_sign_in_failure(p_phone text)
returns void
language sql
security definer
set search_path to ''
as $function$
  insert into private.phone_sign_in_failures (phone_key)
  select private.phone_sign_in_key(p_phone)
  where private.phone_sign_in_key(p_phone) is not null;
$function$;

revoke all on function public.phone_sign_in_candidates(text) from public, anon, authenticated;
revoke all on function public.record_phone_sign_in_failure(text) from public, anon, authenticated;
grant execute on function public.phone_sign_in_candidates(text) to service_role;
grant execute on function public.record_phone_sign_in_failure(text) to service_role;
