-- Seeds the site-wide student auto-approval switch shown on the admin Users page.
--
-- Purely additive: one row in the existing public.app_feature_flags table, off by
-- default. No policy, grant, or gating column is touched here. The flag row only
-- records whether the admin dashboard should approve eligible pending students
-- without a click; the approval itself still goes through the normal admin path
-- (profiles.approved + auth access sync), and RLS remains the real gate.
--
-- The app upserts this row on first save, so this migration is a convenience:
-- it makes the flag visible in the table before anyone toggles it.

begin;

insert into public.app_feature_flags (feature_key, enabled, description)
values (
  'student_auto_approval',
  false,
  'When enabled, pending students whose profile is already complete are approved automatically while an admin dashboard is open.'
)
on conflict (feature_key) do nothing;

commit;
