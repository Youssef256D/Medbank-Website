-- questions
drop policy if exists questions_select_admin on public.questions;
drop policy if exists questions_select_student_enrolled on public.questions;
create policy questions_select on public.questions
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      status = 'published'::app_question_status
      and (select private.can_current_user_access_mcq())
      and private.can_current_user_access_question(course_id, topic_id)
    )
  );

-- question_choices
drop policy if exists choices_select_admin on public.question_choices;
drop policy if exists choices_select_student_enrolled on public.question_choices;
create policy choices_select on public.question_choices
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      (select private.can_current_user_access_mcq())
      and private.can_current_user_access_question_choice(question_id)
    )
  );

-- courses
drop policy if exists courses_select_admin on public.courses;
drop policy if exists courses_select_student_enrolled on public.courses;
create policy courses_select on public.courses
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      is_active is true
      and (select private.can_current_user_access_mcq())
      and exists (
        select 1 from public.user_course_enrollments e
        where e.course_id = courses.id and e.user_id = (select auth.uid())
      )
    )
  );

-- course_topics
drop policy if exists topics_select_admin on public.course_topics;
drop policy if exists topics_select_student_enrolled on public.course_topics;
create policy topics_select on public.course_topics
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      is_active is true
      and (select private.can_current_user_access_mcq())
      and exists (
        select 1
        from public.user_course_enrollments e
        join public.courses c on c.id = e.course_id
        where e.course_id = course_topics.course_id
          and e.user_id = (select auth.uid())
          and c.is_active is true
      )
    )
  );

-- profiles
drop policy if exists profiles_insert_admin on public.profiles;
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert on public.profiles
  for insert to authenticated
  with check (
    (select private.is_admin_user())
    or (
      id = (select auth.uid())
      and role = 'student'::app_user_role
      and approved is false
    )
  );

drop policy if exists profiles_update_admin on public.profiles;
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using (
    (select private.is_admin_user())
    or (id = (select auth.uid()) and role = 'student'::app_user_role)
  )
  with check (
    (select private.is_admin_user())
    or private.can_update_own_profile(id, role, approved, academic_year, academic_semester, mcq_access_enabled, courses_access_enabled)
  );

-- app_feature_flags
drop policy if exists app_feature_flags_select_admin on public.app_feature_flags;
drop policy if exists app_feature_flags_select_public_courses_flag on public.app_feature_flags;
create policy app_feature_flags_select on public.app_feature_flags
  for select to authenticated
  using (
    (select private.is_admin_user())
    or feature_key = 'courses_coming_soon'::text
  );

-- test_block_items
drop policy if exists items_write on public.test_block_items;
drop policy if exists items_select on public.test_block_items;
drop policy if exists items_insert on public.test_block_items;
drop policy if exists items_update on public.test_block_items;
drop policy if exists items_delete on public.test_block_items;

create policy items_select on public.test_block_items
  for select to authenticated
  using (
    exists (
      select 1 from public.test_blocks b
      where b.id = test_block_items.block_id
        and (
          (b.user_id = (select auth.uid()) and (select private.can_current_user_access_mcq()))
          or (select private.is_admin_user())
        )
    )
  );

create policy items_insert on public.test_block_items
  for insert to authenticated
  with check (
    exists (
      select 1 from public.test_blocks b
      where b.id = test_block_items.block_id
        and (b.user_id = (select auth.uid()) or (select private.is_admin_user()))
    )
  );

create policy items_update on public.test_block_items
  for update to authenticated
  using (
    exists (
      select 1 from public.test_blocks b
      where b.id = test_block_items.block_id
        and (b.user_id = (select auth.uid()) or (select private.is_admin_user()))
    )
  )
  with check (
    exists (
      select 1 from public.test_blocks b
      where b.id = test_block_items.block_id
        and (b.user_id = (select auth.uid()) or (select private.is_admin_user()))
    )
  );

create policy items_delete on public.test_block_items
  for delete to authenticated
  using (
    exists (
      select 1 from public.test_blocks b
      where b.id = test_block_items.block_id
        and (
          (b.user_id = (select auth.uid()) and (select private.can_current_user_access_mcq()))
          or (select private.is_admin_user())
        )
    )
  );

-- user_activity_sessions
drop policy if exists user_activity_sessions_select on public.user_activity_sessions;
drop policy if exists user_activity_sessions_insert on public.user_activity_sessions;
drop policy if exists user_activity_sessions_update on public.user_activity_sessions;
drop policy if exists user_activity_sessions_delete on public.user_activity_sessions;

create policy user_activity_sessions_select on public.user_activity_sessions
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin_user()));

create policy user_activity_sessions_insert on public.user_activity_sessions
  for insert to authenticated
  with check (user_id = (select auth.uid()) or (select private.is_admin_user()));

create policy user_activity_sessions_update on public.user_activity_sessions
  for update to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin_user()))
  with check (user_id = (select auth.uid()) or (select private.is_admin_user()));

create policy user_activity_sessions_delete on public.user_activity_sessions
  for delete to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin_user()));;
