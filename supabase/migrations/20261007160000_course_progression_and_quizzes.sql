-- Sequential course progression and in-module quizzes.
--
-- 1. platform_courses.progression_mode: 'open' (today's behaviour) or
--    'sequential'. Coupons still decide WHICH modules a student owns; the mode
--    only decides the ORDER inside what they own. A module the student does
--    not own never counts as a step they must finish, so a partial coupon for
--    modules 2 and 4 opens module 2 at once and module 4 after module 2.
--    Anything a student has already opened (a progress row exists) stays
--    open, so inserting a lesson early in a live course never locks anyone
--    out of where they already are.
--
-- 2. Quizzes are module items: a platform_course_lessons row with
--    lesson_type 'quiz' plus its settings, questions and options. They reuse
--    the lessons' ordering, coupon gating and completion (a passed quiz is a
--    completed lesson). Students never read the correct answers: questions
--    come from get_platform_quiz and grading happens in submit_platform_quiz.
--
-- Enforcement is in the database, so the app, the website and a raw API
-- token all see the same locks.

-- ─── 1. Progression mode ────────────────────────────────────────────────

alter table public.platform_courses
  add column if not exists progression_mode text not null default 'open';

alter table public.platform_courses
  drop constraint if exists platform_courses_progression_mode_ck;
alter table public.platform_courses
  add constraint platform_courses_progression_mode_ck
  check (progression_mode in ('open', 'sequential'));

comment on column public.platform_courses.progression_mode is
  'open: every owned lesson is available. sequential: each owned lesson '
  'opens once every earlier owned lesson (and required quiz) is complete.';

-- ─── 2. Quiz tables ─────────────────────────────────────────────────────

create table if not exists public.platform_course_quizzes (
  lesson_id uuid primary key
    references public.platform_course_lessons (id) on delete cascade,
  course_id uuid not null
    references public.platform_courses (id) on delete cascade,
  pass_percent smallint not null default 70
    check (pass_percent between 0 and 100),
  -- Required: blocks the next item in a sequential course, and only a pass
  -- completes it. Optional: any submitted attempt completes it.
  is_required boolean not null default true,
  -- Null is unlimited.
  max_attempts smallint
    check (max_attempts is null or max_attempts between 1 and 100),
  shuffle_questions boolean not null default false,
  -- Whether a submitted attempt shows the correct answers and explanations.
  show_answers boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_platform_course_quizzes_course
  on public.platform_course_quizzes (course_id);

create table if not exists public.platform_course_quiz_questions (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null
    references public.platform_course_quizzes (lesson_id) on delete cascade,
  course_id uuid not null
    references public.platform_courses (id) on delete cascade,
  position integer not null default 0,
  prompt text not null check (btrim(prompt) <> ''),
  explanation text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_platform_course_quiz_questions_lesson
  on public.platform_course_quiz_questions (lesson_id, position);
create index if not exists idx_platform_course_quiz_questions_course
  on public.platform_course_quiz_questions (course_id);

create table if not exists public.platform_course_quiz_options (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null
    references public.platform_course_quiz_questions (id) on delete cascade,
  course_id uuid not null
    references public.platform_courses (id) on delete cascade,
  position integer not null default 0,
  body text not null check (btrim(body) <> ''),
  is_correct boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_platform_course_quiz_options_question
  on public.platform_course_quiz_options (question_id, position);
create index if not exists idx_platform_course_quiz_options_course
  on public.platform_course_quiz_options (course_id);

create table if not exists public.platform_course_quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null
    references public.platform_course_quizzes (lesson_id) on delete cascade,
  course_id uuid not null
    references public.platform_courses (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- { "<question id>": "<chosen option id>" }
  answers jsonb not null default '{}'::jsonb,
  correct_count integer not null,
  question_count integer not null,
  score_percent numeric(5, 2) not null,
  passed boolean not null,
  submitted_at timestamptz not null default now()
);

create index if not exists idx_platform_course_quiz_attempts_user_lesson
  on public.platform_course_quiz_attempts (user_id, lesson_id);
create index if not exists idx_platform_course_quiz_attempts_lesson
  on public.platform_course_quiz_attempts (lesson_id);
create index if not exists idx_platform_course_quiz_attempts_course
  on public.platform_course_quiz_attempts (course_id);

-- course_id is always derived from the parent row, never trusted from the
-- client: RLS decides ownership by it, so a creator must not be able to file
-- a question under someone else's course.
create or replace function private.platform_quiz_set_course_id()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if tg_table_name = 'platform_course_quizzes' then
    select l.course_id into new.course_id
    from public.platform_course_lessons l
    where l.id = new.lesson_id;
  elsif tg_table_name = 'platform_course_quiz_questions' then
    select q.course_id into new.course_id
    from public.platform_course_quizzes q
    where q.lesson_id = new.lesson_id;
  elsif tg_table_name = 'platform_course_quiz_options' then
    select q.course_id into new.course_id
    from public.platform_course_quiz_questions q
    where q.id = new.question_id;
  end if;
  if new.course_id is null then
    raise exception 'Parent row not found.' using errcode = '23503';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_platform_course_quizzes_course_id
  on public.platform_course_quizzes;
create trigger trg_platform_course_quizzes_course_id
  before insert or update on public.platform_course_quizzes
  for each row execute function private.platform_quiz_set_course_id();

drop trigger if exists trg_platform_course_quiz_questions_course_id
  on public.platform_course_quiz_questions;
create trigger trg_platform_course_quiz_questions_course_id
  before insert or update on public.platform_course_quiz_questions
  for each row execute function private.platform_quiz_set_course_id();

drop trigger if exists trg_platform_course_quiz_options_course_id
  on public.platform_course_quiz_options;
create trigger trg_platform_course_quiz_options_course_id
  before insert or update on public.platform_course_quiz_options
  for each row execute function private.platform_quiz_set_course_id();

drop trigger if exists trg_platform_course_quizzes_updated_at
  on public.platform_course_quizzes;
create trigger trg_platform_course_quizzes_updated_at
  before update on public.platform_course_quizzes
  for each row execute function public.set_updated_at();

drop trigger if exists trg_platform_course_quiz_questions_updated_at
  on public.platform_course_quiz_questions;
create trigger trg_platform_course_quiz_questions_updated_at
  before update on public.platform_course_quiz_questions
  for each row execute function public.set_updated_at();

-- ─── 3. RLS for the quiz tables ─────────────────────────────────────────
-- Authoring tables: the owning creator and admins. Students have no direct
-- access at all — the options table holds is_correct.

alter table public.platform_course_quizzes enable row level security;
alter table public.platform_course_quiz_questions enable row level security;
alter table public.platform_course_quiz_options enable row level security;
alter table public.platform_course_quiz_attempts enable row level security;

do $policies$
declare
  t text;
begin
  foreach t in array array[
    'platform_course_quizzes',
    'platform_course_quiz_questions',
    'platform_course_quiz_options'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_creator_all', t);
    execute format(
      'create policy %I on public.%I for all to authenticated '
      'using (private.owns_platform_course(course_id)) '
      'with check (private.owns_platform_course(course_id))',
      t || '_creator_all', t);

    execute format('drop policy if exists %I on public.%I', t || '_admin_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated '
      'using ((select private.is_admin_user()))',
      t || '_admin_select', t);

    execute format('drop policy if exists %I on public.%I', t || '_admin_insert', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated '
      'with check ((select private.is_admin_user()))',
      t || '_admin_insert', t);

    execute format('drop policy if exists %I on public.%I', t || '_admin_update', t);
    execute format(
      'create policy %I on public.%I for update to authenticated '
      'using ((select private.is_admin_user())) '
      'with check ((select private.is_admin_user()))',
      t || '_admin_update', t);

    execute format('drop policy if exists %I on public.%I', t || '_admin_delete', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated '
      'using ((select private.is_admin_user()))',
      t || '_admin_delete', t);

    -- Same area restriction every other course table carries: an admin
    -- without the video_courses area reads but cannot write.
    execute format('drop policy if exists %I on public.%I', t || '_area_guard_insert', t);
    execute format(
      'create policy %I on public.%I as restrictive for insert to authenticated '
      'with check ((select private.admin_write_allowed(''video_courses'')))',
      t || '_area_guard_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_area_guard_update', t);
    execute format(
      'create policy %I on public.%I as restrictive for update to authenticated '
      'using ((select private.admin_write_allowed(''video_courses''))) '
      'with check ((select private.admin_write_allowed(''video_courses'')))',
      t || '_area_guard_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_area_guard_delete', t);
    execute format(
      'create policy %I on public.%I as restrictive for delete to authenticated '
      'using ((select private.admin_write_allowed(''video_courses'')))',
      t || '_area_guard_delete', t);
  end loop;
end
$policies$;

-- Attempts: written only by submit_platform_quiz. A student reads their own;
-- admins read and delete (resetting a student's attempts).
drop policy if exists platform_course_quiz_attempts_select_own
  on public.platform_course_quiz_attempts;
create policy platform_course_quiz_attempts_select_own
  on public.platform_course_quiz_attempts for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists platform_course_quiz_attempts_admin_select
  on public.platform_course_quiz_attempts;
create policy platform_course_quiz_attempts_admin_select
  on public.platform_course_quiz_attempts for select to authenticated
  using ((select private.is_admin_user()));

drop policy if exists platform_course_quiz_attempts_admin_delete
  on public.platform_course_quiz_attempts;
create policy platform_course_quiz_attempts_admin_delete
  on public.platform_course_quiz_attempts for delete to authenticated
  using ((select private.is_admin_user()));

drop policy if exists platform_course_quiz_attempts_area_guard_delete
  on public.platform_course_quiz_attempts;
create policy platform_course_quiz_attempts_area_guard_delete
  on public.platform_course_quiz_attempts as restrictive for delete to authenticated
  using ((select private.admin_write_allowed('video_courses')));

-- ─── 4. The sequence rule ───────────────────────────────────────────────

-- Whether the signed-in student owns a module: full-course enrollment or an
-- entitlement for that module. The coupon system's own definition.
create or replace function private.student_owns_platform_module(target_module_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.platform_course_modules m
    join public.platform_course_enrollments e
      on e.course_id = m.course_id
     and e.user_id = (select auth.uid())
     and e.access_scope = 'full'
    where m.id = target_module_id
  ) or exists (
    select 1
    from public.platform_course_module_entitlements me
    where me.module_id = target_module_id
      and me.user_id = (select auth.uid())
  );
$function$;

-- Whether a lesson counts as a step that later lessons wait for. Every
-- lesson does; a quiz only when it is required and has questions to pass
-- (an unfinished quiz must never strand a student).
create or replace function private.platform_lesson_blocks_sequence(target_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select case
    when lower(coalesce(l.lesson_type, '')) <> 'quiz' then true
    else exists (
      select 1
      from public.platform_course_quizzes q
      where q.lesson_id = l.id
        and q.is_required is true
        and exists (
          select 1 from public.platform_course_quiz_questions qq
          where qq.lesson_id = q.lesson_id
        )
    )
  end
  from public.platform_course_lessons l
  where l.id = target_lesson_id;
$function$;

-- The sequence half of access only — coupons are checked separately. True
-- for an open course, a free preview, a lesson the student already opened,
-- or when every earlier blocking lesson in a module they own is complete.
-- Course order: module (position, created_at, id), then lesson
-- (position, created_at, id) — ties never flip between calls.
create or replace function private.platform_lesson_sequence_open(target_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
cost 1000
as $function$
  select coalesce((
    select
      c.progression_mode <> 'sequential'
      or l.is_free_preview is true
      or exists (
        select 1
        from public.platform_lesson_progress p
        where p.user_id = (select auth.uid())
          and p.lesson_id = l.id
      )
      or not exists (
        select 1
        from public.platform_course_lessons pl
        join public.platform_course_modules pm on pm.id = pl.module_id
        where pl.course_id = l.course_id
          and pl.id <> l.id
          and pl.is_published is true
          and pm.is_published is true
          and (pm.position, pm.created_at, pm.id, pl.position, pl.created_at, pl.id)
            < (m.position, m.created_at, m.id, l.position, l.created_at, l.id)
          and private.student_owns_platform_module(pm.id)
          and private.platform_lesson_blocks_sequence(pl.id)
          and not exists (
            select 1
            from public.platform_lesson_progress pp
            where pp.user_id = (select auth.uid())
              and pp.lesson_id = pl.id
              and (pp.status = 'completed' or pp.progress_percent >= 100)
          )
      )
    from public.platform_course_lessons l
    join public.platform_course_modules m on m.id = l.module_id
    join public.platform_courses c on c.id = l.course_id
    where l.id = target_lesson_id
  ), true);
$function$;

-- Lesson access = the existing coupon rule AND the sequence rule. Progress
-- writes and lesson materials already go through this function.
create or replace function private.can_access_platform_lesson(target_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select private.is_active_platform_student()
    and exists (
      select 1
      from public.platform_course_lessons l
      join public.platform_course_modules m
        on m.id = l.module_id and m.course_id = l.course_id
      join public.platform_courses c on c.id = l.course_id
      where l.id = target_lesson_id
        and l.is_published is true
        and m.is_published is true
        and c.is_active is true
        and c.is_published is true
        and (
          l.is_free_preview is true
          or exists (
            select 1
            from public.platform_course_enrollments e
            where e.user_id = (select auth.uid())
              and e.course_id = l.course_id
              and e.access_scope = 'full'
          )
          or exists (
            select 1
            from public.platform_course_module_entitlements me
            where me.user_id = (select auth.uid())
              and me.course_id = l.course_id
              and me.module_id = l.module_id
          )
        )
    )
    and private.platform_lesson_sequence_open(target_lesson_id);
$function$;

-- A locked lesson's row (its video id included) is withheld, exactly as a
-- lesson in an unowned module already is.
drop policy if exists platform_lessons_select_student_visible
  on public.platform_course_lessons;
create policy platform_lessons_select_student_visible
  on public.platform_course_lessons for select to authenticated
  using (
    (is_published is true)
    and (
      private.has_platform_module_access(module_id)
      or (
        (is_free_preview is true)
        and private.is_platform_module_published(module_id)
        and private.can_select_platform_course_by_id(course_id)
      )
    )
    and private.platform_lesson_sequence_open(id)
  );

-- A quiz lesson is completed by submit_platform_quiz, not by a client write:
-- otherwise "mark complete" would skip a required quiz.
create or replace function private.guard_quiz_lesson_progress()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if private.is_admin_user() then
    return new;
  end if;
  if (new.status = 'completed' or new.progress_percent >= 100)
     and exists (
       select 1 from public.platform_course_lessons l
       where l.id = new.lesson_id
         and lower(coalesce(l.lesson_type, '')) = 'quiz'
     )
     and not exists (
       select 1
       from public.platform_course_quiz_attempts a
       join public.platform_course_quizzes q on q.lesson_id = a.lesson_id
       where a.lesson_id = new.lesson_id
         and a.user_id = new.user_id
         and (a.passed or q.is_required is false)
     ) then
    raise exception 'quiz_not_passed' using errcode = '42501';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_platform_lesson_progress_quiz_guard
  on public.platform_lesson_progress;
create trigger trg_platform_lesson_progress_quiz_guard
  before insert or update on public.platform_lesson_progress
  for each row execute function private.guard_quiz_lesson_progress();

-- A new quiz is created empty and filled afterwards; announcing it as
-- "a new lesson — tap to watch it" the moment the row exists is wrong twice.
drop trigger if exists notify_students_on_new_lesson
  on public.platform_course_lessons;
create trigger notify_students_on_new_lesson
  after insert or update of is_published on public.platform_course_lessons
  for each row
  when (lower(coalesce(new.lesson_type, '')) <> 'quiz')
  execute function private.notify_students_on_new_lesson();

-- ─── 5. Student RPCs ────────────────────────────────────────────────────

-- The course outline as the signed-in student sees it: every published
-- lesson in a module they own (or a free preview), in course order, with
-- its state. Locked lessons are withheld from the lessons table, so this is
-- where their titles come from.
create or replace function public.get_my_platform_course_progression(p_course_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'course_id', c.id,
    'mode', c.progression_mode,
    'items', coalesce((
      select jsonb_agg(item order by item_order)
      from (
        select
          (m.position, m.created_at, m.id, l.position, l.created_at, l.id) as item_order,
          jsonb_build_object(
            'lesson_id', l.id,
            'module_id', l.module_id,
            'title', l.title,
            'lesson_type', l.lesson_type,
            'position', l.position,
            'duration_seconds', l.duration_seconds,
            'is_free_preview', l.is_free_preview,
            'blocks_sequence', private.platform_lesson_blocks_sequence(l.id),
            'state', case
              when exists (
                select 1 from public.platform_lesson_progress p
                where p.user_id = (select auth.uid())
                  and p.lesson_id = l.id
                  and (p.status = 'completed' or p.progress_percent >= 100)
              ) then 'completed'
              when private.platform_lesson_sequence_open(l.id) then 'available'
              else 'locked'
            end
          ) as item
        from public.platform_course_lessons l
        join public.platform_course_modules m on m.id = l.module_id
        where l.course_id = c.id
          and l.is_published is true
          and m.is_published is true
          and (private.student_owns_platform_module(m.id) or l.is_free_preview is true)
      ) items
    ), '[]'::jsonb)
  )
  from public.platform_courses c
  where c.id = p_course_id
    and private.is_active_platform_student()
    and c.is_active is true
    and c.is_published is true;
$function$;

-- One quiz without its answers, plus the caller's own attempts. Students
-- need the lesson to be open to them; the owning creator and admins can
-- always read it (to preview).
create or replace function public.get_platform_quiz(p_lesson_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  quiz public.platform_course_quizzes%rowtype;
begin
  select * into quiz
  from public.platform_course_quizzes q
  where q.lesson_id = p_lesson_id;
  if not found then
    raise exception 'quiz_not_found' using errcode = 'P0002';
  end if;

  if not (
    private.is_admin_user()
    or private.owns_platform_course(quiz.course_id)
    or private.can_access_platform_lesson(p_lesson_id)
  ) then
    raise exception 'quiz_locked' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'lesson_id', quiz.lesson_id,
    'course_id', quiz.course_id,
    'pass_percent', quiz.pass_percent,
    'is_required', quiz.is_required,
    'max_attempts', quiz.max_attempts,
    'shuffle_questions', quiz.shuffle_questions,
    'show_answers', quiz.show_answers,
    'questions', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', qq.id,
          'prompt', qq.prompt,
          'options', coalesce((
            select jsonb_agg(
              jsonb_build_object('id', o.id, 'body', o.body)
              order by o.position, o.created_at, o.id
            )
            from public.platform_course_quiz_options o
            where o.question_id = qq.id
          ), '[]'::jsonb)
        )
        order by qq.position, qq.created_at, qq.id
      )
      from public.platform_course_quiz_questions qq
      where qq.lesson_id = quiz.lesson_id
    ), '[]'::jsonb),
    'attempts', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', a.id,
          'correct_count', a.correct_count,
          'question_count', a.question_count,
          'score_percent', a.score_percent,
          'passed', a.passed,
          'submitted_at', a.submitted_at
        )
        order by a.submitted_at desc
      )
      from public.platform_course_quiz_attempts a
      where a.lesson_id = quiz.lesson_id
        and a.user_id = (select auth.uid())
    ), '[]'::jsonb)
  );
end;
$function$;

-- Grades an attempt on the server. p_answers: { "<question id>": "<option id>" }.
-- A pass (or any attempt at an optional quiz) completes the quiz lesson.
create or replace function public.submit_platform_quiz(p_lesson_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  uid uuid := (select auth.uid());
  quiz public.platform_course_quizzes%rowtype;
  used integer;
  total integer;
  correct integer;
  score numeric(5, 2);
  did_pass boolean;
  new_attempt_id uuid;
  review jsonb;
begin
  if uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;

  select * into quiz
  from public.platform_course_quizzes q
  where q.lesson_id = p_lesson_id;
  if not found then
    raise exception 'quiz_not_found' using errcode = 'P0002';
  end if;

  if not private.can_access_platform_lesson(p_lesson_id) then
    raise exception 'quiz_locked' using errcode = '42501';
  end if;

  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then
    raise exception 'invalid_answers' using errcode = '22023';
  end if;

  -- Two taps on Submit must not both slip under the attempt limit.
  perform pg_advisory_xact_lock(
    hashtextextended(uid::text || ':' || p_lesson_id::text, 0)
  );

  select count(*) into used
  from public.platform_course_quiz_attempts a
  where a.lesson_id = p_lesson_id and a.user_id = uid;

  if quiz.max_attempts is not null and used >= quiz.max_attempts then
    raise exception 'no_attempts_left' using errcode = 'P0001';
  end if;

  select
    count(*),
    count(*) filter (
      where exists (
        select 1
        from public.platform_course_quiz_options o
        where o.question_id = qq.id
          and o.is_correct is true
          and o.id::text = p_answers ->> qq.id::text
      )
    )
  into total, correct
  from public.platform_course_quiz_questions qq
  where qq.lesson_id = p_lesson_id;

  if total = 0 then
    raise exception 'quiz_empty' using errcode = 'P0001';
  end if;

  score := round(correct::numeric * 100 / total, 2);
  did_pass := score >= quiz.pass_percent;

  insert into public.platform_course_quiz_attempts (
    lesson_id, course_id, user_id, answers,
    correct_count, question_count, score_percent, passed
  ) values (
    p_lesson_id, quiz.course_id, uid, p_answers,
    correct, total, score, did_pass
  )
  returning id into new_attempt_id;

  if did_pass or quiz.is_required is false then
    insert into public.platform_lesson_progress (
      user_id, course_id, lesson_id, status, progress_percent,
      watched_seconds, last_opened_at, completed_at, updated_at
    ) values (
      uid, quiz.course_id, p_lesson_id, 'completed', 100,
      0, now(), now(), now()
    )
    on conflict (user_id, lesson_id) do update set
      status = 'completed',
      progress_percent = 100,
      completed_at = coalesce(public.platform_lesson_progress.completed_at, now()),
      last_opened_at = now(),
      updated_at = now();
  else
    -- Opened, not passed: the row keeps the quiz open to this student even
    -- if the course order changes later.
    insert into public.platform_lesson_progress (
      user_id, course_id, lesson_id, status, progress_percent,
      watched_seconds, last_opened_at, updated_at
    ) values (
      uid, quiz.course_id, p_lesson_id, 'in_progress', 0,
      0, now(), now()
    )
    on conflict (user_id, lesson_id) do update set
      last_opened_at = now(),
      updated_at = now();
  end if;

  if quiz.show_answers then
    select jsonb_agg(
      jsonb_build_object(
        'question_id', qq.id,
        'chosen_option_id', p_answers ->> qq.id::text,
        'correct_option_ids', coalesce((
          select jsonb_agg(o.id order by o.position, o.created_at, o.id)
          from public.platform_course_quiz_options o
          where o.question_id = qq.id and o.is_correct is true
        ), '[]'::jsonb),
        'explanation', qq.explanation
      )
      order by qq.position, qq.created_at, qq.id
    )
    into review
    from public.platform_course_quiz_questions qq
    where qq.lesson_id = p_lesson_id;
  end if;

  return jsonb_build_object(
    'attempt_id', new_attempt_id,
    'correct_count', correct,
    'question_count', total,
    'score_percent', score,
    'passed', did_pass,
    'pass_percent', quiz.pass_percent,
    'is_required', quiz.is_required,
    'attempts_used', used + 1,
    'max_attempts', quiz.max_attempts,
    'review', review
  );
end;
$function$;

-- ─── 6. Creator / admin RPCs ────────────────────────────────────────────

-- Results for one quiz. The owning creator gets the aggregate; an admin also
-- gets each student's best result, for support ("why is X locked?").
create or replace function public.get_platform_quiz_stats(p_lesson_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  quiz public.platform_course_quizzes%rowtype;
  is_admin boolean := private.is_admin_user();
begin
  select * into quiz
  from public.platform_course_quizzes q
  where q.lesson_id = p_lesson_id;
  if not found then
    raise exception 'quiz_not_found' using errcode = 'P0002';
  end if;
  if not (is_admin or private.owns_platform_course(quiz.course_id)) then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'lesson_id', p_lesson_id,
    'attempts', (
      select count(*) from public.platform_course_quiz_attempts a
      where a.lesson_id = p_lesson_id
    ),
    'students', (
      select count(distinct a.user_id) from public.platform_course_quiz_attempts a
      where a.lesson_id = p_lesson_id
    ),
    'students_passed', (
      select count(distinct a.user_id) from public.platform_course_quiz_attempts a
      where a.lesson_id = p_lesson_id and a.passed
    ),
    'average_score', (
      select round(avg(a.score_percent), 1) from public.platform_course_quiz_attempts a
      where a.lesson_id = p_lesson_id
    ),
    'by_student', case when is_admin then coalesce((
      select jsonb_agg(row_data order by row_data ->> 'full_name')
      from (
        select jsonb_build_object(
          'user_id', a.user_id,
          'full_name', p.full_name,
          'public_user_id', p.public_user_id,
          'attempts', count(*),
          'best_score', max(a.score_percent),
          'passed', bool_or(a.passed),
          'last_attempt_at', max(a.submitted_at)
        ) as row_data
        from public.platform_course_quiz_attempts a
        join public.profiles p on p.id = a.user_id
        where a.lesson_id = p_lesson_id
        group by a.user_id, p.full_name, p.public_user_id
      ) s
    ), '[]'::jsonb) else null end
  );
end;
$function$;

-- Support tools for admins with the video_courses area.

-- Opens one lesson for one student regardless of order (a progress row is
-- what keeps a lesson open), e.g. after a creator reshuffled a live course.
create or replace function public.admin_unlock_platform_lesson(p_user_id uuid, p_lesson_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  target_course uuid;
begin
  if not private.admin_has_area('video_courses') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select l.course_id into target_course
  from public.platform_course_lessons l
  where l.id = p_lesson_id;
  if target_course is null then
    raise exception 'lesson_not_found' using errcode = 'P0002';
  end if;
  insert into public.platform_lesson_progress (
    user_id, course_id, lesson_id, status, progress_percent,
    watched_seconds, last_opened_at, updated_at
  ) values (
    p_user_id, target_course, p_lesson_id, 'in_progress', 0, 0, now(), now()
  )
  on conflict (user_id, lesson_id) do nothing;
end;
$function$;

-- Clears a student's attempts at one quiz and un-completes it, giving them
-- a fresh set of attempts.
create or replace function public.admin_reset_platform_quiz_attempts(p_user_id uuid, p_lesson_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path to ''
as $function$
begin
  if not private.admin_has_area('video_courses') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  delete from public.platform_course_quiz_attempts a
  where a.user_id = p_user_id and a.lesson_id = p_lesson_id;
  update public.platform_lesson_progress p
  set status = 'in_progress',
      progress_percent = 0,
      completed_at = null,
      updated_at = now()
  where p.user_id = p_user_id and p.lesson_id = p_lesson_id;
end;
$function$;

revoke all on function public.get_my_platform_course_progression(uuid) from public, anon;
revoke all on function public.get_platform_quiz(uuid) from public, anon;
revoke all on function public.submit_platform_quiz(uuid, jsonb) from public, anon;
revoke all on function public.get_platform_quiz_stats(uuid) from public, anon;
revoke all on function public.admin_unlock_platform_lesson(uuid, uuid) from public, anon;
revoke all on function public.admin_reset_platform_quiz_attempts(uuid, uuid) from public, anon;

grant execute on function public.get_my_platform_course_progression(uuid) to authenticated;
grant execute on function public.get_platform_quiz(uuid) to authenticated;
grant execute on function public.submit_platform_quiz(uuid, jsonb) to authenticated;
grant execute on function public.get_platform_quiz_stats(uuid) to authenticated;
grant execute on function public.admin_unlock_platform_lesson(uuid, uuid) to authenticated;
grant execute on function public.admin_reset_platform_quiz_attempts(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
