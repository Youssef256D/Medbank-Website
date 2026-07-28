-- Students should only receive notifications created on or after their
-- MedBank profile was created. Admins retain full notification visibility.

begin;

alter table public.notifications enable row level security;

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
      and exists (
        select 1
        from public.profiles as notification_profile
        where notification_profile.id = (select auth.uid())
          and notification_profile.created_at <= notifications.created_at
      )
    )
  );

comment on policy notifications_select on public.notifications is
  'Admins can read all notifications; users can read only active eligible notifications created after their profile.';

commit;
