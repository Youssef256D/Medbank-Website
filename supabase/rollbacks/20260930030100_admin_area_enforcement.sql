-- Rollback for 20260930030100_admin_area_enforcement.sql.
-- Drops every restrictive guard it added and restores the three RPC bodies.
-- Apply this BEFORE rolling back 20260930030000 (these reference its functions).

do $rollback$
declare
  policy record;
  target record;
  definition text;
begin
  for policy in
    select schemaname, tablename, policyname
    from pg_policies
    where (schemaname = 'public' and (policyname like '%\_area\_guard\_%' or policyname like '%\_super\_guard%'
                                      or policyname like 'app\_state\_site\_maintenance\_%\_guard\_%'))
       or (schemaname = 'storage' and policyname like 'storage\_objects\_area\_guard\_%')
  loop
    execute format('drop policy if exists %I on %I.%I', policy.policyname, policy.schemaname, policy.tablename);
  end loop;

  for target in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_generate_platform_course_coupons', 'admin_disable_platform_course_coupon', 'admin_review_platform_course')
  loop
    definition := pg_get_functiondef(target.oid);
    execute replace(definition, 'private.admin_has_area(''video_courses'')', 'private.is_admin_user()');
  end loop;
end;
$rollback$;

drop function if exists private.admin_storage_write_allowed(text);
