-- Rollback for 20261027125000_server_side_grading.sql.
-- Restores the two student SELECT policies and the four catalog functions to
-- their 2026-10-27 definitions, and
-- drops the grading RPCs, the reveal log and the switch.
-- Faster undo without a rollback: update private.grading_settings set hide_answer_keys = false;

drop policy if exists questions_select on public.questions;
create policy questions_select on public.questions
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      status = 'published'::public.app_question_status
      and (select private.can_current_user_access_mcq())
      and private.can_current_user_access_question(course_id, topic_id)
    )
  );

drop policy if exists choices_select on public.question_choices;
create policy choices_select on public.question_choices
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      (select private.can_current_user_access_mcq())
      and private.can_current_user_access_question_choice(question_id)
    )
  );

create or replace function private.accessible_catalog_rows(
  only_ids uuid[] default null::uuid[],
  after_id uuid default null::uuid,
  row_limit integer default null::integer
)
returns table(id uuid, external_id text, course_id uuid, topic_id uuid, author_id uuid, stem text, explanation text, objective text, difficulty smallint, status public.app_question_status, created_at timestamp with time zone, sort_order integer, question_image_url text, explanation_image_url text, course_name text, topic_name text, choices jsonb)
language sql
stable security definer
set search_path to ''
as $function$
  with access_context as materialized (
    select
      private.is_admin_user() as is_admin,
      private.can_current_user_access_mcq() as can_access_mcq
  ),
  accessible_topics as materialized (
    select topic.id as topic_id, topic.course_id, topic.topic_name,
           course.course_name
    from public.course_topics as topic
    join public.courses as course on course.id = topic.course_id
    cross join access_context
    where access_context.is_admin
      or (
        access_context.can_access_mcq
        and private.can_current_user_access_question(topic.course_id, topic.id)
      )
  ),
  picked as (
    select question.*, t.topic_name, t.course_name
    from public.questions as question
    join accessible_topics as t
      on t.topic_id = question.topic_id
     and t.course_id = question.course_id
    cross join access_context
    where (access_context.is_admin
           or question.status = 'published'::public.app_question_status)
      and (only_ids is null or question.id = any (only_ids))
      and (after_id is null or question.id > after_id)
    order by question.id
    limit row_limit
  )
  select
    question.id, question.external_id, question.course_id, question.topic_id,
    question.author_id, question.stem, question.explanation,
    question.objective, question.difficulty, question.status,
    question.created_at, question.sort_order, question.question_image_url,
    question.explanation_image_url, question.course_name, question.topic_name,
    coalesce(choice_rows.choices, '[]'::jsonb) as choices
  from picked as question
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'question_id', choice.question_id,
        'choice_label', choice.choice_label,
        'choice_text', choice.choice_text,
        'is_correct', choice.is_correct
      )
      order by choice.choice_label
    ) as choices
    from public.question_choices as choice
    where choice.question_id = question.id
  ) as choice_rows on true
  order by question.id;
$function$;

create or replace function private.get_accessible_question_catalog_page(
  requested_limit integer default 500,
  requested_offset integer default 0
)
returns table(id uuid, external_id text, course_id uuid, topic_id uuid, author_id uuid, stem text, explanation text, objective text, difficulty smallint, status public.app_question_status, created_at timestamp with time zone, sort_order integer, question_image_url text, explanation_image_url text, course_name text, topic_name text, choices jsonb)
language sql
stable security definer
set search_path to ''
as $function$
  with access_context as materialized (
    select
      private.is_admin_user() as is_admin,
      private.can_current_user_access_mcq() as can_access_mcq
  ),
  accessible_questions as materialized (
    select question.*
    from public.questions as question
    cross join access_context
    where access_context.is_admin
      or (
        question.status = 'published'::public.app_question_status
        and access_context.can_access_mcq
        and private.can_current_user_access_question(question.course_id, question.topic_id)
      )
    order by question.sort_order asc nulls last, question.created_at asc, question.id asc
    limit greatest(1, least(coalesce(requested_limit, 500), 1000))
    offset greatest(0, coalesce(requested_offset, 0))
  )
  select
    question.id,
    question.external_id,
    question.course_id,
    question.topic_id,
    question.author_id,
    question.stem,
    question.explanation,
    question.objective,
    question.difficulty,
    question.status,
    question.created_at,
    question.sort_order,
    question.question_image_url,
    question.explanation_image_url,
    course.course_name,
    topic.topic_name,
    coalesce(choice_rows.choices, '[]'::jsonb) as choices
  from accessible_questions as question
  join public.courses as course on course.id = question.course_id
  join public.course_topics as topic
    on topic.id = question.topic_id
   and topic.course_id = question.course_id
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'question_id', choice.question_id,
        'choice_label', choice.choice_label,
        'choice_text', choice.choice_text,
        'is_correct', choice.is_correct
      )
      order by choice.choice_label
    ) as choices
    from public.question_choices as choice
    where choice.question_id = question.id
  ) as choice_rows on true
  order by question.sort_order asc nulls last, question.created_at asc, question.id asc;
$function$;

create or replace function private.get_accessible_questions_page(
  requested_limit integer default 500,
  requested_offset integer default 0
)
returns setof public.questions
language sql
stable security definer
set search_path to ''
as $function$
  with access_context as materialized (
    select
      private.is_admin_user() as is_admin,
      private.can_current_user_access_mcq() as can_access_mcq
  )
  select question.*
  from public.questions as question
  cross join access_context
  where access_context.is_admin
    or (
      question.status = 'published'::public.app_question_status
      and access_context.can_access_mcq
      and private.can_current_user_access_question(question.course_id, question.topic_id)
    )
  order by question.sort_order asc nulls last, question.created_at asc, question.id asc
  limit greatest(1, least(coalesce(requested_limit, 500), 1000))
  offset greatest(0, coalesce(requested_offset, 0));
$function$;

create or replace function private.get_accessible_question_choices(target_question_ids uuid[])
returns table(question_id uuid, choice_label text, choice_text text, is_correct boolean)
language sql
stable security definer
set search_path to ''
as $function$
  with access_context as materialized (
    select
      private.is_admin_user() as is_admin,
      private.can_current_user_access_mcq() as can_access_mcq
  ),
  accessible_questions as materialized (
    select question.id
    from public.questions as question
    cross join access_context
    where question.id = any(coalesce(target_question_ids, array[]::uuid[]))
      and (
        access_context.is_admin
        or (
          question.status = 'published'::public.app_question_status
          and access_context.can_access_mcq
          and private.can_current_user_access_question(question.course_id, question.topic_id)
        )
      )
  )
  select
    choice.question_id,
    choice.choice_label,
    choice.choice_text,
    choice.is_correct
  from public.question_choices as choice
  join accessible_questions
    on accessible_questions.id = choice.question_id
  order by choice.question_id asc, choice.choice_label asc;
$function$;

-- private.protect_test_response_answer is left as it is: its "solved stays
-- solved" rule is shared with 20261027130000_shared_test_write_rpcs, which
-- needs it too. If that migration is not applied and the 2026-10-25 body is
-- wanted back, take it from 20261025200000_protect_test_response_answers.sql.

drop function if exists public.get_test_answer_key(uuid, uuid[]);
drop function if exists public.submit_test_answer(uuid, uuid, text[], boolean, text);
drop function if exists private.answer_key_rows(uuid[]);
drop function if exists private.claim_answer_key_reveals(uuid, uuid[], uuid[]);
drop table if exists private.answer_key_reveals;
drop function if exists private.answer_keys_hidden();
drop table if exists private.grading_settings;
