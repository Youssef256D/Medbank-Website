-- Admin layers, part 2: enforce areas in the database.
--
-- Additive and reversible: no existing policy is changed. Each table gets
-- RESTRICTIVE policies (ANDed with the existing permissive ones) for INSERT,
-- UPDATE and DELETE. Their condition is private.admin_write_allowed(area),
-- which is true for anyone who is not an admin, so students and creators are
-- unaffected, and for admins only when they hold the area (super admins hold
-- all). Reads are not restricted: pages read across areas (Notifications
-- lists users, Video Courses shows enrollments), and every admin could
-- already read everything.
--
-- Where admins write rows that are their own (profile, presence, their own
-- test attempts, notification reads), the own-row case stays allowed.
--
-- Super-only: the Hermes tables (all commands, including reads) and the Site
-- Access setting (app_state key g:mcq_site_maintenance).
--
-- The rollback drops every policy named *_area_guard_* / *_super_guard* and
-- restores the three RPC bodies.

do $migration$
declare
  spec record;
  guard text;
begin
  for spec in
    select * from (values
      -- table, area, own-row condition (null = none)
      ('profiles', 'people', 'id = (select auth.uid())'),
      ('user_course_enrollments', 'people', null),
      ('universities', 'people', null),
      ('user_devices', 'people', null),
      ('user_device_exemptions', 'people', null),
      ('device_integrity_exemptions', 'people', null),
      ('test_blocks', 'people', 'user_id = (select auth.uid())'),
      ('test_history_entries', 'people', 'user_id = (select auth.uid())'),
      ('test_block_items', 'people', 'exists (select 1 from public.test_blocks b where b.id = block_id and b.user_id = (select auth.uid()))'),
      ('test_responses', 'people', 'exists (select 1 from public.test_blocks b where b.id = block_id and b.user_id = (select auth.uid()))'),
      ('courses', 'mcq', null),
      ('course_topics', 'mcq', null),
      ('questions', 'mcq', null),
      ('question_choices', 'mcq', null),
      ('bulk_import_uploads', 'mcq', null),
      ('platform_courses', 'video_courses', null),
      ('platform_course_modules', 'video_courses', null),
      ('platform_course_lessons', 'video_courses', null),
      ('platform_course_resources', 'video_courses', null),
      ('platform_course_announcements', 'video_courses', null),
      ('platform_course_suggestions', 'video_courses', null),
      ('platform_course_enrollments', 'video_courses', null),
      ('platform_course_enrollment_requests', 'video_courses', 'user_id = (select auth.uid())'),
      ('platform_lesson_progress', 'video_courses', 'user_id = (select auth.uid())'),
      ('notifications', 'messaging', null),
      ('notification_reads', 'messaging', 'user_id = (select auth.uid())'),
      ('app_popups', 'messaging', null),
      ('user_presence', 'system', 'user_id = (select auth.uid())'),
      ('user_activity_sessions', 'system', 'user_id = (select auth.uid())')
    ) as t(table_name, area, own_row)
  loop
    guard := format('(select private.admin_write_allowed(%L))', spec.area);
    if spec.own_row is not null then
      guard := format('((%s) or %s)', spec.own_row, guard);
    end if;

    execute format('drop policy if exists %I on public.%I', spec.table_name || '_area_guard_insert', spec.table_name);
    execute format('drop policy if exists %I on public.%I', spec.table_name || '_area_guard_update', spec.table_name);
    execute format('drop policy if exists %I on public.%I', spec.table_name || '_area_guard_delete', spec.table_name);
    execute format(
      'create policy %I on public.%I as restrictive for insert to authenticated with check (%s)',
      spec.table_name || '_area_guard_insert', spec.table_name, guard);
    execute format(
      'create policy %I on public.%I as restrictive for update to authenticated using (%s) with check (%s)',
      spec.table_name || '_area_guard_update', spec.table_name, guard, guard);
    execute format(
      'create policy %I on public.%I as restrictive for delete to authenticated using (%s)',
      spec.table_name || '_area_guard_delete', spec.table_name, guard);
  end loop;
end;
$migration$;

-- Feature flags belong to different pages: the Users switches (People) and
-- "courses coming soon" (Video Courses).
drop policy if exists app_feature_flags_area_guard_insert on public.app_feature_flags;
drop policy if exists app_feature_flags_area_guard_update on public.app_feature_flags;
drop policy if exists app_feature_flags_area_guard_delete on public.app_feature_flags;
create policy app_feature_flags_area_guard_insert
  on public.app_feature_flags as restrictive for insert to authenticated
  with check (private.admin_write_allowed(case when feature_key = 'courses_coming_soon' then 'video_courses' else 'people' end));
create policy app_feature_flags_area_guard_update
  on public.app_feature_flags as restrictive for update to authenticated
  using (private.admin_write_allowed(case when feature_key = 'courses_coming_soon' then 'video_courses' else 'people' end))
  with check (private.admin_write_allowed(case when feature_key = 'courses_coming_soon' then 'video_courses' else 'people' end));
create policy app_feature_flags_area_guard_delete
  on public.app_feature_flags as restrictive for delete to authenticated
  using (private.admin_write_allowed(case when feature_key = 'courses_coming_soon' then 'video_courses' else 'people' end));

-- Hermes (AI admin assistant): super admins only, reads included. The agent
-- itself runs through the admin-agent-tool Edge Function with the service
-- role, which RLS does not apply to.
do $migration$
declare
  table_name text;
begin
  foreach table_name in array array['admin_agents', 'admin_agent_permissions', 'admin_agent_approval_requests', 'admin_agent_action_log']
  loop
    execute format('drop policy if exists %I on public.%I', table_name || '_super_guard', table_name);
    execute format(
      'create policy %I on public.%I as restrictive for all to authenticated using ((select private.admin_super_allowed())) with check ((select private.admin_super_allowed()))',
      table_name || '_super_guard', table_name);
  end loop;
end;
$migration$;

-- ---------------------------------------------------------------------------
-- Storage buckets by area. Other buckets and non-admin uploads (creators'
-- course files, students) are unaffected.
-- ---------------------------------------------------------------------------
create or replace function private.admin_storage_write_allowed(target_bucket text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when target_bucket in ('question-images', 'bulk-import-uploads') then private.admin_write_allowed('mcq')
    when target_bucket in ('course-covers', 'course-materials', 'course-videos') then private.admin_write_allowed('video_courses')
    when target_bucket = 'popup-images' then private.admin_write_allowed('messaging')
    else true
  end;
$$;
revoke all on function private.admin_storage_write_allowed(text) from public;
grant execute on function private.admin_storage_write_allowed(text) to authenticated, service_role;

drop policy if exists storage_objects_area_guard_insert on storage.objects;
drop policy if exists storage_objects_area_guard_update on storage.objects;
drop policy if exists storage_objects_area_guard_delete on storage.objects;
create policy storage_objects_area_guard_insert
  on storage.objects as restrictive for insert to authenticated
  with check (private.admin_storage_write_allowed(bucket_id));
create policy storage_objects_area_guard_update
  on storage.objects as restrictive for update to authenticated
  using (private.admin_storage_write_allowed(bucket_id))
  with check (private.admin_storage_write_allowed(bucket_id));
create policy storage_objects_area_guard_delete
  on storage.objects as restrictive for delete to authenticated
  using (private.admin_storage_write_allowed(bucket_id));

-- ---------------------------------------------------------------------------
-- Site Access: the maintenance setting lives in app_state, whose global keys
-- any client (even signed out) can write. Only a super admin may write this
-- one key. anon gets its own policy without the private function, which anon
-- cannot execute (a function call in its expression would fail every anon
-- write to app_state, not just this key).
-- ---------------------------------------------------------------------------
drop policy if exists app_state_site_maintenance_super_guard_insert on public.app_state;
drop policy if exists app_state_site_maintenance_super_guard_update on public.app_state;
drop policy if exists app_state_site_maintenance_anon_guard_insert on public.app_state;
drop policy if exists app_state_site_maintenance_anon_guard_update on public.app_state;
create policy app_state_site_maintenance_super_guard_insert
  on public.app_state as restrictive for insert to authenticated
  with check (storage_key <> 'g:mcq_site_maintenance' or (select private.is_super_admin()));
create policy app_state_site_maintenance_super_guard_update
  on public.app_state as restrictive for update to authenticated
  using (storage_key <> 'g:mcq_site_maintenance' or (select private.is_super_admin()))
  with check (storage_key <> 'g:mcq_site_maintenance' or (select private.is_super_admin()));
create policy app_state_site_maintenance_anon_guard_insert
  on public.app_state as restrictive for insert to anon
  with check (storage_key <> 'g:mcq_site_maintenance');
create policy app_state_site_maintenance_anon_guard_update
  on public.app_state as restrictive for update to anon
  using (storage_key <> 'g:mcq_site_maintenance')
  with check (storage_key <> 'g:mcq_site_maintenance');

-- ---------------------------------------------------------------------------
-- Functions that write while bypassing RLS need the area themselves: the
-- coupon generator, coupon disabling and course review (all Video Courses).
-- The body is taken from the live definition and only the admin check is
-- replaced, so nothing else in these functions changes.
-- ---------------------------------------------------------------------------
do $migration$
declare
  target record;
  definition text;
  patched text;
begin
  for target in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_generate_platform_course_coupons', 'admin_disable_platform_course_coupon', 'admin_review_platform_course')
  loop
    definition := pg_get_functiondef(target.oid);
    patched := replace(definition, 'private.is_admin_user()', 'private.admin_has_area(''video_courses'')');
    if patched = definition then
      raise exception 'Admin check not found in %', target.oid::regprocedure;
    end if;
    execute patched;
  end loop;
end;
$migration$;
