-- MCQ module locks: universal (all students) and per student.
--
--   public.course_locks       one row = the module is locked for every student.
--   public.user_course_locks  one row = this student's override for a module:
--                             locked = true  locks it for this student only;
--                             locked = false unlocks it for this student even
--                             while the module is universally locked.
--
-- Effective rule: the student's override if one exists, else the universal
-- lock. A locked module stays visible to the student (the enrollment and
-- courses_select are untouched) so the website and the app can show it with a
-- lock and a "contact admin" message, but its questions and choices are no
-- longer readable: the rule is checked inside
-- private.can_current_user_access_question, which questions_select and
-- choices_select already call. Admins are unaffected (is_admin_user short-
-- circuits both policies).
--
-- Separate tables rather than columns on user_course_enrollments / courses:
-- enrollments are deleted and re-created when a student's term changes, and
-- both tables are rewritten by the admin sync; locks must survive that.
--
-- Rollback: supabase/rollbacks/20261013190634_user_course_locks.down.sql

create table public.course_locks (
  course_id uuid primary key references public.courses (id) on delete cascade,
  note text check (note is null or char_length(note) <= 500),
  locked_at timestamptz not null default now(),
  locked_by uuid default auth.uid() references auth.users (id) on delete set null
);

create index course_locks_locked_by_idx on public.course_locks (locked_by);

comment on table public.course_locks is
  'MCQ modules locked for every student. Per-student overrides in user_course_locks win.';

create table public.user_course_locks (
  user_id uuid not null references auth.users (id) on delete cascade,
  course_id uuid not null references public.courses (id) on delete cascade,
  locked boolean not null default true,
  note text check (note is null or char_length(note) <= 500),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  primary key (user_id, course_id)
);

create index user_course_locks_course_id_idx on public.user_course_locks (course_id);
create index user_course_locks_updated_by_idx on public.user_course_locks (updated_by);

comment on table public.user_course_locks is
  'Per-student MCQ module lock overrides: locked=true locks, locked=false unlocks a universally locked module.';

alter table public.course_locks enable row level security;
alter table public.user_course_locks enable row level security;

revoke all on public.course_locks from anon, authenticated;
revoke all on public.user_course_locks from anon, authenticated;
grant select, insert, update, delete on public.course_locks to authenticated;
grant select, insert, update, delete on public.user_course_locks to authenticated;

-- Universal locks name a module and an optional message; nothing private.
create policy course_locks_select
  on public.course_locks for select to authenticated
  using (true);

create policy course_locks_insert
  on public.course_locks for insert to authenticated
  with check ((select private.is_admin_user()));

create policy course_locks_update
  on public.course_locks for update to authenticated
  using ((select private.is_admin_user()))
  with check ((select private.is_admin_user()));

create policy course_locks_delete
  on public.course_locks for delete to authenticated
  using ((select private.is_admin_user()));

create policy user_course_locks_select
  on public.user_course_locks for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin_user()));

create policy user_course_locks_insert
  on public.user_course_locks for insert to authenticated
  with check ((select private.is_admin_user()));

create policy user_course_locks_update
  on public.user_course_locks for update to authenticated
  using ((select private.is_admin_user()))
  with check ((select private.is_admin_user()));

create policy user_course_locks_delete
  on public.user_course_locks for delete to authenticated
  using ((select private.is_admin_user()));

-- Admin layers. Universal locks belong to the MCQ area ("mcq.subjects", the
-- action that manages modules); per-student locks to People ("users.access",
-- the action that turns a student's MCQ access on and off).
create policy course_locks_area_guard_insert
  on public.course_locks as restrictive for insert to authenticated
  with check ((select private.admin_write_allowed('mcq')));

create policy course_locks_area_guard_update
  on public.course_locks as restrictive for update to authenticated
  using ((select private.admin_write_allowed('mcq')))
  with check ((select private.admin_write_allowed('mcq')));

create policy course_locks_area_guard_delete
  on public.course_locks as restrictive for delete to authenticated
  using ((select private.admin_write_allowed('mcq')));

create policy user_course_locks_area_guard_insert
  on public.user_course_locks as restrictive for insert to authenticated
  with check ((select private.admin_write_allowed('people')));

create policy user_course_locks_area_guard_update
  on public.user_course_locks as restrictive for update to authenticated
  using ((select private.admin_write_allowed('people')))
  with check ((select private.admin_write_allowed('people')));

create policy user_course_locks_area_guard_delete
  on public.user_course_locks as restrictive for delete to authenticated
  using ((select private.admin_write_allowed('people')));

create trigger trg_course_locks_aa_admin_action_before
  before update or delete on public.course_locks
  for each row execute function private.guard_admin_action('mcq.subjects', 'mcq.subjects', 'mcq.subjects');

create trigger trg_course_locks_admin_action_after_insert
  after insert on public.course_locks
  for each row execute function private.guard_admin_action('mcq.subjects', 'mcq.subjects', 'mcq.subjects');

create trigger trg_user_course_locks_aa_admin_action_before
  before update or delete on public.user_course_locks
  for each row execute function private.guard_admin_action('users.access', 'users.access', 'users.access');

create trigger trg_user_course_locks_admin_action_after_insert
  after insert on public.user_course_locks
  for each row execute function private.guard_admin_action('users.access', 'users.access', 'users.access');

-- Same body as before plus the final NOT EXISTS: the enrolled module and the
-- question's module must both be unlocked for this student (override first,
-- then the universal lock).
create or replace function private.can_current_user_access_question(target_course_id uuid, target_topic_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.user_course_enrollments e
    join public.courses enrolled_course on enrolled_course.id = e.course_id
    join public.courses question_course on question_course.id = target_course_id
    join public.course_topics question_topic on question_topic.id = target_topic_id
    where e.user_id = (select auth.uid())
      and enrolled_course.is_active is true
      and question_course.is_active is true
      and question_topic.is_active is true
      and question_topic.course_id = question_course.id
      and enrolled_course.academic_year = question_course.academic_year
      and enrolled_course.academic_semester = question_course.academic_semester
      and (
        enrolled_course.id = question_course.id
        or (
          private.course_code_key(enrolled_course.course_code) <> ''
          and private.course_code_key(enrolled_course.course_code)
            = private.course_code_key(question_course.course_code)
        )
        or private.course_name_key(enrolled_course.course_name)
          = private.course_name_key(question_course.course_name)
      )
      and not exists (
        select 1
        from (values (e.course_id), (question_course.id)) as checked(course_id)
        where coalesce(
          (select o.locked
             from public.user_course_locks o
            where o.user_id = e.user_id and o.course_id = checked.course_id),
          exists (select 1 from public.course_locks g where g.course_id = checked.course_id)
        )
      )
  );
$function$;

alter publication supabase_realtime add table public.course_locks, public.user_course_locks;
