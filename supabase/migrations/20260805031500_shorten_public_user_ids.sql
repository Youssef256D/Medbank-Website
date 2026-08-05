begin;

-- ---------------------------------------------------------------------------
-- Shorten public user IDs from 8 digits (>= 10000001) to compact IDs starting
-- at 100 (3 digits, growing to 4-5 digits as accounts grow). Auth UUIDs remain
-- the canonical internal key. public_user_id remains immutable to clients; the
-- protect trigger is bypassed only inside this migration, which runs as the
-- table owner. No other table stores public_user_id (coupon/report RPCs derive
-- it live by joining profiles), so renumbering is self-contained.
-- ---------------------------------------------------------------------------

alter table public.profiles disable trigger trg_profiles_protect_public_user_id;

alter table public.profiles
  drop constraint if exists profiles_public_user_id_positive_ck;

alter sequence public.profiles_public_user_id_seq minvalue 100;

-- New values (100..N) cannot collide with existing 8-digit values, so the
-- unique constraint is safe during this one-statement renumber.
with renumbered as (
  select id, 99 + row_number() over (order by created_at, id) as next_public_user_id
  from public.profiles
)
update public.profiles p
set public_user_id = r.next_public_user_id
from renumbered r
where p.id = r.id;

select setval(
  'public.profiles_public_user_id_seq'::regclass,
  greatest(coalesce((select max(public_user_id) from public.profiles), 99), 99),
  true
);

alter table public.profiles
  add constraint profiles_public_user_id_positive_ck
  check (public_user_id >= 100);

alter table public.profiles enable trigger trg_profiles_protect_public_user_id;

commit;
