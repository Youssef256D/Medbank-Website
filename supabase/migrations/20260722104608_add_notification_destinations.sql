-- Add an optional, strictly allowlisted student SPA destination to notifications.
-- Existing rows remain valid and continue to open the notifications page.

alter table public.notifications
  add column if not exists target_route text;

alter table public.notifications
  drop constraint if exists notifications_target_route_check;

alter table public.notifications
  add constraint notifications_target_route_check
  check (
    target_route is null
    or target_route in (
      'app-launcher',
      'dashboard',
      'create-test',
      'analytics',
      'video-courses',
      'profile'
    )
  );

comment on column public.notifications.target_route is
  'Optional allowlisted MedBank student SPA route opened when the notification is selected.';
