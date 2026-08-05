begin;

-- Rollback: return public user IDs to the 8-digit range (>= 10000001).
-- Original ID values cannot be restored exactly; profiles are renumbered in
-- created_at order, matching how the original backfill assigned them.

alter table public.profiles disable trigger trg_profiles_protect_public_user_id;

alter table public.profiles
  drop constraint if exists profiles_public_user_id_positive_ck;

with renumbered as (
  select id, 10000000 + row_number() over (order by created_at, id) as next_public_user_id
  from public.profiles
)
update public.profiles p
set public_user_id = r.next_public_user_id
from renumbered r
where p.id = r.id;

select setval(
  'public.profiles_public_user_id_seq'::regclass,
  greatest(coalesce((select max(public_user_id) from public.profiles), 10000000), 10000000),
  true
);

alter sequence public.profiles_public_user_id_seq minvalue 10000001;

alter table public.profiles
  add constraint profiles_public_user_id_positive_ck
  check (public_user_id >= 10000001);

alter table public.profiles enable trigger trg_profiles_protect_public_user_id;

commit;
