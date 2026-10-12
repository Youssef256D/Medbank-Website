-- Rollback for 20261011184347_performance_advisor_fixes.sql

alter policy app_popup_views_own on public.app_popup_views
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

alter policy content_protection_events_insert_own on public.content_protection_events
  with check (user_id = auth.uid());

drop index if exists public.idx_admin_permissions_updated_by;
drop index if exists public.idx_app_popup_views_user_id;
drop index if exists public.idx_app_popups_created_by;
drop index if exists public.idx_device_integrity_exemptions_created_by;
drop index if exists public.idx_integrity_challenges_user_id;
drop index if exists public.idx_platform_course_coupons_created_by;
drop index if exists public.idx_platform_course_coupons_disabled_by;
drop index if exists public.idx_platform_course_coupons_redeemed_by;
drop index if exists public.idx_platform_course_module_entitlements_granted_by;
drop index if exists public.idx_platform_course_module_entitlements_module_id;
drop index if exists public.idx_platform_courses_reviewed_by;
drop index if exists public.idx_user_device_exemptions_created_by;
