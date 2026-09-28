-- Anonymous visitors cannot execute private.is_admin_user(), so a single
-- select policy that mentioned it failed the whole read for the signed-out
-- sign-up form (42501). The anon policy must not reference it.
drop policy if exists universities_select on public.universities;
create policy universities_select_public on public.universities
  for select to anon
  using (is_active);
create policy universities_select_authenticated on public.universities
  for select to authenticated
  using (is_active or (select private.is_admin_user()));
