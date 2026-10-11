-- Performance-advisor fixes (2026-10-11). No access changes.
-- Applied to the hosted project via the Supabase MCP apply_migration
-- (ledger version 20261011184347); this file records it.
--
-- 1. auth_rls_initplan: two policies called auth.uid() once per row. Wrapping
--    it in (select ...) makes Postgres evaluate it once per query. Same
--    predicate, same names (app_popup_views is owned by the Flutter repo's
--    20260910120000_app_popups, so the policy is altered, not recreated).
-- 2. unindexed_foreign_keys: covering indexes for 12 foreign keys, so deleting
--    a profile / module no longer scans these tables to check references.
--
-- Deliberately NOT done: merging the 45 "multiple permissive policies".
-- Several of those policies are rewritten by name from the Flutter repo
-- (e.g. platform_lessons_select_student_visible, 2026-10-07); folding them
-- into merged policies would leave a stale copy of the old predicate behind
-- the next time one is dropped and recreated by name.

alter policy app_popup_views_own on public.app_popup_views
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

alter policy content_protection_events_insert_own on public.content_protection_events
  with check (user_id = (select auth.uid()));

create index if not exists idx_admin_permissions_updated_by on public.admin_permissions (updated_by);
create index if not exists idx_app_popup_views_user_id on public.app_popup_views (user_id);
create index if not exists idx_app_popups_created_by on public.app_popups (created_by);
create index if not exists idx_device_integrity_exemptions_created_by on public.device_integrity_exemptions (created_by);
create index if not exists idx_integrity_challenges_user_id on public.integrity_challenges (user_id);
create index if not exists idx_platform_course_coupons_created_by on public.platform_course_coupons (created_by);
create index if not exists idx_platform_course_coupons_disabled_by on public.platform_course_coupons (disabled_by);
create index if not exists idx_platform_course_coupons_redeemed_by on public.platform_course_coupons (redeemed_by);
create index if not exists idx_platform_course_module_entitlements_granted_by on public.platform_course_module_entitlements (granted_by);
create index if not exists idx_platform_course_module_entitlements_module_id on public.platform_course_module_entitlements (module_id);
create index if not exists idx_platform_courses_reviewed_by on public.platform_courses (reviewed_by);
create index if not exists idx_user_device_exemptions_created_by on public.user_device_exemptions (created_by);
