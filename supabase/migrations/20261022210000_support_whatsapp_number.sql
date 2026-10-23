-- The support WhatsApp number, set by an admin instead of shipped in a build.
--
-- One `app_state` row, `g:support_whatsapp`, payload
-- `{"number": "201004532728", "updated_at": ..., "updated_by": ...}`: digits
-- only, country code first, the form `wa.me` expects. Everyone can read it
-- (the support bubble is on the sign-in screen, before there is a session).
--
-- `g:` keys are otherwise writable by anyone, signed in or not, because the
-- website keeps shared state there. Left like that, anyone could point every
-- student's "Contact support" at their own WhatsApp. These restrictive
-- policies make this one key admin-only and digits-only, the same way
-- `g:mcq_site_maintenance` is guarded.

create policy app_state_support_whatsapp_anon_guard_insert
  on public.app_state as restrictive for insert to anon
  with check (storage_key <> 'g:support_whatsapp');

create policy app_state_support_whatsapp_anon_guard_update
  on public.app_state as restrictive for update to anon
  using (storage_key <> 'g:support_whatsapp')
  with check (storage_key <> 'g:support_whatsapp');

create policy app_state_support_whatsapp_admin_guard_insert
  on public.app_state as restrictive for insert to authenticated
  with check (
    storage_key <> 'g:support_whatsapp'
    or (
      (select private.is_admin_user())
      and payload ->> 'number' ~ '^[0-9]{8,15}$'
    )
  );

create policy app_state_support_whatsapp_admin_guard_update
  on public.app_state as restrictive for update to authenticated
  using (
    storage_key <> 'g:support_whatsapp' or (select private.is_admin_user())
  )
  with check (
    storage_key <> 'g:support_whatsapp'
    or (
      (select private.is_admin_user())
      and payload ->> 'number' ~ '^[0-9]{8,15}$'
    )
  );

insert into public.app_state (storage_key, payload, updated_at)
values (
  'g:support_whatsapp',
  jsonb_build_object('number', '201004532728'),
  now()
)
on conflict (storage_key) do nothing;
