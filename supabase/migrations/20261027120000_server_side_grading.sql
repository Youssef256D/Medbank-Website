-- Server-side grading: students get answer keys only after answering.
--
-- Plan: docs/plans/server-side-grading.md (approved by the owner 2026-10-27).
-- Rollback: supabase/rollbacks/20261027120000_server_side_grading.down.sql
--
-- Phase 1 (this migration): the switch private.grading_settings.hide_answer_keys
-- starts FALSE, so nothing changes for any client. The new RPCs
-- (submit_test_answer, get_test_answer_key) work either way, so updated
-- website/app builds can grade through them right away.
-- Phase 2 (owner's call, once most students run an updated app):
--   update private.grading_settings set hide_answer_keys = true;
-- From then on, for non-admins:
--   * the catalog RPCs return is_correct = null, explanation = '' and
--     explanation_image_url = null;
--   * questions_select / choices_select stop letting students read the tables.
-- Setting it back to false is the emergency undo.
--
-- Always on (both phases):
--   * a solved test_responses row (selection + submitted) keeps its answer;
--   * every key handed to a student is logged in private.answer_key_reveals,
--     capped at daily_reveal_cap distinct questions per rolling 24 h.

-- 1. Switch ------------------------------------------------------------------

create table if not exists private.grading_settings (
  id boolean primary key default true check (id),
  hide_answer_keys boolean not null default false,
  daily_reveal_cap integer not null default 2500 check (daily_reveal_cap > 0),
  updated_at timestamptz not null default now()
);

insert into private.grading_settings (id) values (true)
on conflict (id) do nothing;

revoke all on private.grading_settings from public, anon, authenticated;

create or replace function private.answer_keys_hidden()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select settings.hide_answer_keys from private.grading_settings as settings where settings.id),
    false
  );
$$;

revoke all on function private.answer_keys_hidden() from public, anon;
grant execute on function private.answer_keys_hidden() to authenticated;

-- 2. Reveal log --------------------------------------------------------------

-- One row per (student, question): the first time a key was handed out.
-- A question already revealed to that student never counts again.
create table if not exists private.answer_key_reveals (
  user_id uuid not null references public.profiles (id) on delete cascade,
  question_id uuid not null references public.questions (id) on delete cascade,
  block_id uuid,
  answered boolean not null,
  first_revealed_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

create index if not exists answer_key_reveals_user_time_idx
  on private.answer_key_reveals (user_id, first_revealed_at desc);

revoke all on private.answer_key_reveals from public, anon, authenticated;

-- Returns the subset of p_question_ids whose keys the caller may receive
-- now, logging first reveals. Questions beyond the daily cap are left out.
-- p_answered_ids: the questions in this batch the student actually answered.
create or replace function private.claim_answer_key_reveals(
  p_block_id uuid,
  p_question_ids uuid[],
  p_answered_ids uuid[]
)
returns uuid[]
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_cap integer;
  v_used integer;
  v_room integer;
  v_allowed uuid[];
  v_new uuid[];
begin
  if v_uid is null or coalesce(cardinality(p_question_ids), 0) = 0 then
    return '{}'::uuid[];
  end if;
  if private.is_admin_user() then
    return p_question_ids;
  end if;

  select settings.daily_reveal_cap into v_cap
  from private.grading_settings as settings where settings.id;
  v_cap := coalesce(v_cap, 2500);

  select count(*) into v_used
  from private.answer_key_reveals as reveal
  where reveal.user_id = v_uid
    and reveal.first_revealed_at > now() - interval '24 hours';
  v_room := greatest(0, v_cap - v_used);

  -- Already revealed before: always allowed, never counted again.
  select coalesce(array_agg(reveal.question_id), '{}'::uuid[]) into v_allowed
  from private.answer_key_reveals as reveal
  where reveal.user_id = v_uid
    and reveal.question_id = any (p_question_ids);

  -- New ones, answered questions first, while there is room.
  select coalesce(array_agg(picked.qid), '{}'::uuid[]) into v_new
  from (
    select ids.qid
    from (select distinct unnest(p_question_ids) as qid) as ids
    where not (ids.qid = any (v_allowed))
    order by (ids.qid = any (coalesce(p_answered_ids, '{}'::uuid[]))) desc, ids.qid
    limit v_room
  ) as picked;

  if cardinality(v_new) > 0 then
    insert into private.answer_key_reveals (user_id, question_id, block_id, answered)
    select v_uid, qid, p_block_id, qid = any (coalesce(p_answered_ids, '{}'::uuid[]))
    from unnest(v_new) as qid
    on conflict (user_id, question_id) do nothing;
  end if;

  return v_allowed || v_new;
end;
$$;

revoke all on function private.claim_answer_key_reveals(uuid, uuid[], uuid[]) from public, anon, authenticated;

-- Key rows for the given questions (no access checks; callers check).
create or replace function private.answer_key_rows(p_question_ids uuid[])
returns table (
  question_id uuid,
  correct_labels text[],
  explanation text,
  explanation_image_url text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    question.id,
    coalesce(
      (select array_agg(upper(choice.choice_label) order by upper(choice.choice_label))
       from public.question_choices as choice
       where choice.question_id = question.id and choice.is_correct),
      '{}'::text[]
    ),
    coalesce(question.explanation, ''),
    question.explanation_image_url
  from public.questions as question
  where question.id = any (coalesce(p_question_ids, '{}'::uuid[]));
$$;

revoke all on function private.answer_key_rows(uuid[]) from public, anon, authenticated;

-- 3. Answers are final -------------------------------------------------------

-- 2026-10-25 body, plus: once a row is solved (selection + submitted), an
-- update keeps the stored selection, submitted and answered_at (flag and notes
-- still update). Keys are handed out for solved rows, so changing the answer
-- afterwards would let a student grade themselves after seeing the key.
-- The shared-test RPC work (2026-10-27) needs the same rule; keep one body.
create or replace function private.protect_test_response_answer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
     and old.submitted
     and coalesce(cardinality(old.selected_choice_labels), 0) > 0 then
    new.selected_choice_labels := old.selected_choice_labels;
    new.submitted := true;
    new.answered_at := old.answered_at;
  end if;

  if tg_op = 'UPDATE'
     and coalesce(cardinality(new.selected_choice_labels), 0) = 0
     and coalesce(cardinality(old.selected_choice_labels), 0) > 0 then
    new.selected_choice_labels := old.selected_choice_labels;
    new.submitted := old.submitted;
    new.answered_at := old.answered_at;
  end if;

  if coalesce(cardinality(new.selected_choice_labels), 0) = 0 then
    new.submitted := false;
  end if;

  return new;
end;
$$;

-- 4. RPCs --------------------------------------------------------------------

-- Tutor mode: store a submitted answer and return the key in one round trip.
-- The stored answer wins when the question was already solved (another device
-- or an earlier call), and that stored answer is what comes back.
-- A finished test takes no new answers; the stored row and key come back.
create or replace function public.submit_test_answer(
  p_block_id uuid,
  p_question_id uuid,
  p_selected_labels text[],
  p_flagged boolean default null,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean := private.is_admin_user();
  v_block public.test_blocks;
  v_labels text[];
  v_row public.test_responses;
  v_allowed uuid[];
  v_key record;
  v_selected text[];
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select * into v_block from public.test_blocks where id = p_block_id;
  if v_block.id is null
     or (v_block.user_id <> v_uid and not v_is_admin)
     or (not v_is_admin and not private.can_current_user_access_mcq()) then
    raise exception 'Test not found' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.test_block_items as item
    where item.block_id = p_block_id and item.question_id = p_question_id
  ) then
    raise exception 'Question is not part of this test' using errcode = '22023';
  end if;

  if not v_is_admin and not private.can_current_user_access_question_choice(p_question_id) then
    raise exception 'Question not available' using errcode = '42501';
  end if;

  -- Labels A-E that exist on this question, upper-cased, sorted, unique.
  select coalesce(array_agg(distinct upper(btrim(label)) order by upper(btrim(label))), '{}'::text[])
  into v_labels
  from unnest(coalesce(p_selected_labels, '{}'::text[])) as label
  where upper(btrim(label)) in ('A', 'B', 'C', 'D', 'E')
    and exists (
      select 1 from public.question_choices as choice
      where choice.question_id = p_question_id
        and upper(choice.choice_label) = upper(btrim(label))
    );

  if v_block.status <> 'completed'::public.app_block_status and cardinality(v_labels) > 0 then
    insert into public.test_responses as response (
      block_id, question_id, selected_choice_labels, flagged, notes, submitted, answered_at
    ) values (
      p_block_id, p_question_id, v_labels, coalesce(p_flagged, false), p_notes, true, now()
    )
    on conflict (block_id, question_id) do update set
      selected_choice_labels = excluded.selected_choice_labels,
      submitted = true,
      answered_at = coalesce(response.answered_at, excluded.answered_at),
      flagged = coalesce(p_flagged, response.flagged),
      notes = coalesce(p_notes, response.notes);
    -- protect_test_response_answer keeps an earlier solved answer.
  end if;

  select * into v_row from public.test_responses
  where block_id = p_block_id and question_id = p_question_id;

  v_selected := coalesce(v_row.selected_choice_labels, '{}'::text[]);

  if (coalesce(v_row.submitted, false) and cardinality(v_selected) > 0)
     or v_block.status = 'completed'::public.app_block_status then
    v_allowed := private.claim_answer_key_reveals(
      p_block_id,
      array[p_question_id],
      case when coalesce(v_row.submitted, false) and cardinality(v_selected) > 0
        then array[p_question_id] else '{}'::uuid[] end
    );
  else
    v_allowed := '{}'::uuid[];
  end if;

  if not (p_question_id = any (v_allowed)) then
    return jsonb_build_object(
      'question_id', p_question_id,
      'selected_labels', to_jsonb(v_selected),
      'submitted', coalesce(v_row.submitted, false),
      'graded', false,
      'capped', coalesce(v_row.submitted, false) and cardinality(v_selected) > 0
    );
  end if;

  select * into v_key from private.answer_key_rows(array[p_question_id]);

  return jsonb_build_object(
    'question_id', p_question_id,
    'selected_labels', to_jsonb(v_selected),
    'submitted', coalesce(v_row.submitted, false),
    'graded', true,
    'capped', false,
    'correct_labels', to_jsonb(v_key.correct_labels),
    'is_correct', cardinality(v_selected) > 0
      and (select array_agg(upper(s) order by upper(s)) from unnest(v_selected) as s)
        = v_key.correct_labels,
    'explanation', v_key.explanation,
    'explanation_image_url', v_key.explanation_image_url
  );
end;
$$;

revoke all on function public.submit_test_answer(uuid, uuid, text[], boolean, text) from public, anon;
grant execute on function public.submit_test_answer(uuid, uuid, text[], boolean, text) to authenticated;

-- Keys for a test's questions: those with a solved response, or every
-- question once the test is finished. p_question_ids narrows the set.
-- capped = true: the student may see it, but not today (daily cap).
create or replace function public.get_test_answer_key(
  p_block_id uuid,
  p_question_ids uuid[] default null
)
returns table (
  question_id uuid,
  correct_labels text[],
  explanation text,
  explanation_image_url text,
  capped boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean := private.is_admin_user();
  v_block public.test_blocks;
  v_eligible uuid[];
  v_answered uuid[];
  v_allowed uuid[];
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select * into v_block from public.test_blocks where id = p_block_id;
  if v_block.id is null
     or (v_block.user_id <> v_uid and not v_is_admin)
     or (not v_is_admin and not private.can_current_user_access_mcq()) then
    raise exception 'Test not found' using errcode = '42501';
  end if;

  select
    coalesce(array_agg(item.question_id), '{}'::uuid[]),
    coalesce(array_agg(item.question_id) filter (where response.submitted
      and coalesce(cardinality(response.selected_choice_labels), 0) > 0), '{}'::uuid[])
  into v_eligible, v_answered
  from public.test_block_items as item
  left join public.test_responses as response
    on response.block_id = item.block_id and response.question_id = item.question_id
  where item.block_id = p_block_id
    and (p_question_ids is null or item.question_id = any (p_question_ids))
    and (
      v_block.status = 'completed'::public.app_block_status
      or (response.submitted and coalesce(cardinality(response.selected_choice_labels), 0) > 0)
    )
    and (v_is_admin or private.can_current_user_access_question_choice(item.question_id));

  v_allowed := private.claim_answer_key_reveals(p_block_id, v_eligible, v_answered);

  return query
  select key.question_id, key.correct_labels, key.explanation, key.explanation_image_url, false
  from private.answer_key_rows(v_allowed) as key
  union all
  select capped_id, null::text[], null::text, null::text, true
  from unnest(v_eligible) as capped_id
  where not (capped_id = any (v_allowed));
end;
$$;

revoke all on function public.get_test_answer_key(uuid, uuid[]) from public, anon;
grant execute on function public.get_test_answer_key(uuid, uuid[]) to authenticated;

-- 5. Catalog RPCs hide the key when the switch is on --------------------------

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
      private.can_current_user_access_mcq() as can_access_mcq,
      (not private.is_admin_user() and private.answer_keys_hidden()) as hide_keys
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
    question.author_id, question.stem,
    case when access_context.hide_keys then '' else question.explanation end,
    question.objective, question.difficulty, question.status,
    question.created_at, question.sort_order, question.question_image_url,
    case when access_context.hide_keys then null else question.explanation_image_url end,
    question.course_name, question.topic_name,
    coalesce(choice_rows.choices, '[]'::jsonb) as choices
  from picked as question
  cross join access_context
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'question_id', choice.question_id,
        'choice_label', choice.choice_label,
        'choice_text', choice.choice_text,
        'is_correct', case when access_context.hide_keys then null else choice.is_correct end
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
      private.can_current_user_access_mcq() as can_access_mcq,
      (not private.is_admin_user() and private.answer_keys_hidden()) as hide_keys
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
    case when access_context.hide_keys then '' else question.explanation end,
    question.objective,
    question.difficulty,
    question.status,
    question.created_at,
    question.sort_order,
    question.question_image_url,
    case when access_context.hide_keys then null else question.explanation_image_url end,
    course.course_name,
    topic.topic_name,
    coalesce(choice_rows.choices, '[]'::jsonb) as choices
  from accessible_questions as question
  cross join access_context
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
        'is_correct', case when access_context.hide_keys then null else choice.is_correct end
      )
      order by choice.choice_label
    ) as choices
    from public.question_choices as choice
    where choice.question_id = question.id
  ) as choice_rows on true
  order by question.sort_order asc nulls last, question.created_at asc, question.id asc;
$function$;

-- Column list must follow public.questions' column order (returns SETOF questions).
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
      private.can_current_user_access_mcq() as can_access_mcq,
      (not private.is_admin_user() and private.answer_keys_hidden()) as hide_keys
  )
  select
    question.id,
    question.course_id,
    question.topic_id,
    question.author_id,
    question.stem,
    case when access_context.hide_keys then '' else question.explanation end,
    question.objective,
    question.difficulty,
    question.status,
    question.created_at,
    question.updated_at,
    question.external_id,
    question.question_image_url,
    case when access_context.hide_keys then null else question.explanation_image_url end,
    question.sort_order
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
      private.can_current_user_access_mcq() as can_access_mcq,
      (not private.is_admin_user() and private.answer_keys_hidden()) as hide_keys
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
    case when access_context.hide_keys then null else choice.is_correct end
  from public.question_choices as choice
  cross join access_context
  join accessible_questions
    on accessible_questions.id = choice.question_id
  order by choice.question_id asc, choice.choice_label asc;
$function$;

-- 6. RLS: students stop reading the tables when the switch is on --------------
-- Owner approved this policy change on 2026-10-27. Only the two student
-- SELECT policies change; admin, write and area-guard policies are untouched.

drop policy if exists questions_select on public.questions;
create policy questions_select on public.questions
  for select to authenticated
  using (
    (select private.is_admin_user())
    or (
      not (select private.answer_keys_hidden())
      and status = 'published'::public.app_question_status
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
      not (select private.answer_keys_hidden())
      and (select private.can_current_user_access_mcq())
      and private.can_current_user_access_question_choice(question_id)
    )
  );
