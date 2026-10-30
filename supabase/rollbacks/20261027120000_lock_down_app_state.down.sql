-- Rollback for 20261027120000_lock_down_app_state.sql: restores the
-- app_state policies exactly as they were (anon and every signed-in user can
-- read and write g:% and the legacy raw keys). Only use to unbreak a client;
-- it re-opens the exposure the migration closed.

drop policy if exists app_state_select_anon on public.app_state;
drop policy if exists app_state_select_authenticated on public.app_state;
drop policy if exists app_state_insert_authenticated on public.app_state;
drop policy if exists app_state_update_authenticated on public.app_state;

create policy app_state_select_anon
  on public.app_state for select to anon
  using (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
  );

create policy app_state_insert_anon
  on public.app_state for insert to anon
  with check (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
  );

create policy app_state_update_anon
  on public.app_state for update to anon
  using (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
  )
  with check (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
  );

create policy app_state_select_authenticated
  on public.app_state for select to authenticated
  using (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
    or (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
  );

create policy app_state_insert_authenticated
  on public.app_state for insert to authenticated
  with check (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
    or (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
  );

create policy app_state_update_authenticated
  on public.app_state for update to authenticated
  using (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
    or (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
  )
  with check (
    storage_key like 'g:%'
    or storage_key = any (array['mcq_users', 'mcq_questions', 'mcq_filter_presets', 'mcq_invites', 'mcq_feedback', 'mcq_curriculum', 'mcq_course_topics'])
    or (
      split_part(storage_key, ':', 1) = 'u'
      and split_part(storage_key, ':', 2) = (select auth.uid())::text
      and split_part(storage_key, ':', 3) = any (array['mcq_sessions', 'mcq_incorrect_queue', 'mcq_flashcards'])
    )
  );
