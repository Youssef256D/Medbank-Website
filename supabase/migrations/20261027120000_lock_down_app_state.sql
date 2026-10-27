-- Lock down app_state reads and writes.
--
-- Before this, every `g:%` key and the legacy raw keys (mcq_users,
-- mcq_questions, ...) could be read AND written by the anon role, i.e. by
-- anyone holding the public anon key, signed in or not. That exposed the
-- frozen 2026-06-13 question-bank backup (answers included), the legacy user
-- list and the admin system log, and let anyone overwrite shared state.
--
-- After this:
--   anon           reads g:mcq_site_maintenance and g:support_whatsapp
--                  (both shown before sign-in); writes nothing.
--   authenticated  reads the six global keys the website's signed-in refresh
--                  hydrates plus the support number, and its own
--                  u:<uid>:<key> rows; writes only its own u: rows.
--   admins         read and write every g:% and legacy key, as before.
--
-- The restrictive guards on g:mcq_site_maintenance, g:support_whatsapp and
-- g:mcq_course_notebook_links are untouched and still apply on top.
-- app_state_no_delete is untouched. Edge Functions use the service role and
-- are unaffected.
--
-- Rollback: supabase/rollbacks/20261027120000_lock_down_app_state.down.sql

drop policy if exists app_state_select_anon on public.app_state;
drop policy if exists app_state_insert_anon on public.app_state;
drop policy if exists app_state_update_anon on public.app_state;
drop policy if exists app_state_select_authenticated on public.app_state;
drop policy if exists app_state_insert_authenticated on public.app_state;
drop policy if exists app_state_update_authenticated on public.app_state;

create policy app_state_select_anon
  on public.app_state for select to anon
  using (storage_key in ('g:mcq_site_maintenance', 'g:support_whatsapp'));

create policy app_state_select_authenticated
  on public.app_state for select to authenticated
  using (
    storage_key in (
      'g:mcq_site_maintenance',
      'g:support_whatsapp',
      'g:mcq_course_topic_groups',
      'g:mcq_course_notebook_links',
      'g:mcq_topic_new_catalog',
      'g:mcq_auto_approve_student_access',
      'g:mcq_student_refresh_trigger'
    )
    or (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
    or (select private.is_admin_user())
  );

create policy app_state_insert_authenticated
  on public.app_state for insert to authenticated
  with check (
    (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
    or (
      (select private.is_admin_user())
      and (
        storage_key like 'g:%'
        or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
      )
    )
  );

create policy app_state_update_authenticated
  on public.app_state for update to authenticated
  using (
    (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
    or (
      (select private.is_admin_user())
      and (
        storage_key like 'g:%'
        or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
      )
    )
  )
  with check (
    (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
    or (
      (select private.is_admin_user())
      and (
        storage_key like 'g:%'
        or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
      )
    )
  );
