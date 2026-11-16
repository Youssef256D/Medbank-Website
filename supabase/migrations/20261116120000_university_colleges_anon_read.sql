-- university_colleges had one SELECT policy for anon AND authenticated whose
-- expression calls private.is_admin_user(). anon cannot execute that
-- function, so every signed-out read of the table failed with
-- "permission denied for function is_admin_user" (42501), even for active
-- rows. Split it the way public.universities already is: signed-out visitors
-- read active colleges; signed-in users read active ones, admins all of them.

drop policy if exists university_colleges_select on public.university_colleges;
drop policy if exists university_colleges_select_public on public.university_colleges;
drop policy if exists university_colleges_select_authenticated on public.university_colleges;

create policy university_colleges_select_public
  on public.university_colleges
  for select
  to anon
  using (is_active);

create policy university_colleges_select_authenticated
  on public.university_colleges
  for select
  to authenticated
  using (is_active or (select private.is_admin_user()));

notify pgrst, 'reload schema';
