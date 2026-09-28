-- Auto MCQ activation for new students.
--
-- `app_feature_flags.student_auto_mcq_access`:
--   * on  — an eligible student (Medicine at a university with the MCQ Bank)
--           gets MCQ access the moment their account exists, as before;
--   * off — they are created with MCQ access off and `mcq_access_held_at`
--           set: "waiting for an admin". An admin activates them one by one
--           (setting mcq_access_enabled clears the hold), or turns the switch
--           back on, which activates everyone still held.
--
-- Only accounts held *by this switch* are released when it comes back on; a
-- student an admin switched off by hand has no hold and stays off. Ineligible
-- students are never held — they cannot have the MCQ Bank either way.

insert into public.app_feature_flags (feature_key, enabled, description)
values (
  'student_auto_mcq_access',
  true,
  'When enabled, new eligible students get MCQ Bank access immediately. When disabled, new accounts wait for an admin to activate MCQ access; turning it back on activates everyone still waiting.'
)
on conflict (feature_key) do nothing;

alter table public.profiles
  add column if not exists mcq_access_held_at timestamptz;

create index if not exists profiles_mcq_access_held_idx
  on public.profiles (mcq_access_held_at)
  where mcq_access_held_at is not null;

create or replace function private.enforce_profile_mcq_eligibility()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  caller uuid := (select auth.uid());
  caller_is_admin boolean := coalesce((select private.is_admin_user()), false);
  eligible boolean;
  was_eligible boolean := false;
begin
  -- A student editing their own row can never touch their MCQ state.
  if tg_op = 'UPDATE' and caller is not null and caller = new.id
     and not caller_is_admin then
    new.mcq_access_enabled := old.mcq_access_enabled;
    new.mcq_access_held_at := old.mcq_access_held_at;
  end if;

  -- A student may only pick a university that is on the public list.
  if caller is not null and not caller_is_admin
     and new.university_id is not null
     and (tg_op = 'INSERT' or new.university_id is distinct from old.university_id)
     and not exists (
       select 1 from public.universities u
       where u.id = new.university_id and u.is_active
     ) then
    raise exception using errcode = '23514', message = 'UNIVERSITY_NOT_AVAILABLE';
  end if;

  eligible := private.is_mcq_eligible(new.role, new.university_id, new.college);
  if tg_op = 'UPDATE' then
    was_eligible := private.is_mcq_eligible(old.role, old.university_id, old.college);
  end if;

  if not eligible then
    new.mcq_access_enabled := false;
  elsif new.role = 'student'::public.app_user_role
        and (tg_op = 'INSERT' or not was_eligible) then
    -- Becoming eligible (a new account, or one that just filled in its
    -- university/college): the switch decides. With it on, an insert keeps
    -- the value it was created with (the column default is on).
    if not private.is_app_feature_enabled('student_auto_mcq_access') then
      new.mcq_access_enabled := false;
      new.mcq_access_held_at := now();
    elsif tg_op = 'UPDATE' then
      new.mcq_access_enabled := true;
    end if;
  end if;

  -- A hold only means something while access is off and could be granted.
  if new.mcq_access_enabled or not eligible
     or new.role <> 'student'::public.app_user_role then
    new.mcq_access_held_at := null;
  end if;

  return new;
end;
$$;

-- Turning the switch back on releases everyone it held.
create or replace function private.release_held_mcq_access()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  if new.feature_key = 'student_auto_mcq_access'
     and new.enabled is true and old.enabled is not true then
    update public.profiles
    set mcq_access_enabled = true
    where mcq_access_held_at is not null
      and role = 'student'::public.app_user_role;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_feature_flags_release_mcq on public.app_feature_flags;
create trigger trg_feature_flags_release_mcq
  after update of enabled on public.app_feature_flags
  for each row execute function private.release_held_mcq_access();
