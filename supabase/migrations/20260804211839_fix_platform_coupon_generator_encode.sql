begin;

create or replace function private.generate_platform_coupon_plaintext()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  raw_value text;
begin
  loop
    raw_value := upper(encode(extensions.gen_random_bytes(12), 'hex'));
    exit when raw_value !~ '[01]';
  end loop;
  return 'MBK-'
    || substr(raw_value, 1, 4) || '-'
    || substr(raw_value, 5, 4) || '-'
    || substr(raw_value, 9, 4) || '-'
    || substr(raw_value, 13, 4) || '-'
    || substr(raw_value, 17, 4) || '-'
    || substr(raw_value, 21, 4);
end;
$$;

revoke all on function private.generate_platform_coupon_plaintext() from public, anon, authenticated;

commit;
