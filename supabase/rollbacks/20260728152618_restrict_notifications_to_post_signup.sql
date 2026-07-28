begin;

drop policy if exists notifications_select on public.notifications;
create policy notifications_select
  on public.notifications
  for select
  to authenticated
  using (
    (select private.is_admin_user())
    or (
      is_active = true
      and (
        recipient_user_id is null
        or recipient_user_id = (select auth.uid())
      )
    )
  );

comment on policy notifications_select on public.notifications is null;

commit;
