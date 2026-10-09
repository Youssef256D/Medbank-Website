-- Pop-ups may open a website.
--
-- A new target, 'external', next to the in-app screens. Its address is
-- `target_url`, which exists only with that target and only as an https
-- link: the app hands it to the browser, so a plain-http or custom-scheme
-- address is refused here rather than trusted there.
--
-- An app built before this reads 'external' as an unknown route and opens
-- the notifications screen, which is harmless.

alter table public.app_popups
  add column target_url text;

alter table public.app_popups
  add constraint app_popups_target_url_https
    check (
      target_url is null
      or (target_url ~* '^https://[^\s/?#]+\.[^\s/?#]+' and length(target_url) <= 2048)
    );

alter table public.app_popups
  add constraint app_popups_target_url_pairing
    check ((target_route is not distinct from 'external') = (target_url is not null));

alter table public.app_popups drop constraint app_popups_target_route_check;
alter table public.app_popups add constraint app_popups_target_route_check
  check (target_route = any (array[
    'app-launcher', 'dashboard', 'create-test', 'analytics', 'video-courses',
    'profile', 'notifications', 'join-organization', 'external'
  ]));

comment on column public.app_popups.target_url is
  'https address opened in the browser when target_route is external; null otherwise.';
