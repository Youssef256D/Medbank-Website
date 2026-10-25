-- Student results: "bank covered" only counts questions that are still
-- published in that subject (or topic). Answers to questions that were later
-- deleted, unpublished or moved made it go over 100% (e.g. 743 of 571).
-- Same signatures, so grants are kept. Rollback: re-run the definitions in
-- 20261026120000_admin_student_results.sql.

create or replace function public.admin_results_subjects(
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_year smallint default null,
  p_semester smallint default null,
  p_university_id uuid default null
)
returns table (
  course_id uuid,
  course_name text,
  course_code text,
  academic_year smallint,
  academic_semester smallint,
  is_active boolean,
  students bigint,
  tests bigint,
  answered bigint,
  correct bigint,
  questions_answered bigint,
  published_questions bigint,
  last_answered_at timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $$
#variable_conflict use_column
begin
  if not private.admin_has_area('people') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  return query
  with students as (
    select p.id
    from public.profiles p
    where p.role::text = 'student'
      and (p_year is null or p.academic_year = p_year)
      and (p_semester is null or p.academic_semester = p_semester)
      and (p_university_id is null or p.university_id = p_university_id)
  ),
  agg as (
    select a.course_id,
           count(distinct a.user_id) as students,
           count(distinct a.history_id) as tests,
           count(*) as answered,
           count(*) filter (where a.is_correct) as correct,
           count(distinct a.question_id) filter (where q.id is not null) as questions_answered,
           max(a.completed_at) as last_answered_at
    from public.test_history_answers a
    join students s on s.id = a.user_id
    left join public.questions q
      on q.id = a.question_id and q.course_id = a.course_id and q.status::text = 'published'
    where a.course_id is not null
      and (p_from is null or a.completed_at >= p_from)
      and (p_to is null or a.completed_at < p_to)
    group by a.course_id
  ),
  published as (
    select q.course_id, count(*) as n
    from public.questions q
    where q.status::text = 'published'
    group by q.course_id
  )
  select c.id, c.course_name, c.course_code, c.academic_year, c.academic_semester, c.is_active,
         coalesce(agg.students, 0), coalesce(agg.tests, 0), coalesce(agg.answered, 0),
         coalesce(agg.correct, 0), coalesce(agg.questions_answered, 0), coalesce(pub.n, 0),
         agg.last_answered_at
  from public.courses c
  left join agg on agg.course_id = c.id
  left join published pub on pub.course_id = c.id
  where agg.course_id is not null or (c.is_active and coalesce(pub.n, 0) > 0)
  order by coalesce(agg.answered, 0) desc, c.course_name;
end;
$$;

create or replace function public.admin_results_topics(
  p_course_id uuid,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_year smallint default null,
  p_semester smallint default null,
  p_university_id uuid default null
)
returns table (
  topic_id uuid,
  topic_name text,
  sort_order integer,
  is_active boolean,
  students bigint,
  answered bigint,
  correct bigint,
  questions_answered bigint,
  published_questions bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
#variable_conflict use_column
begin
  if not private.admin_has_area('people') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  return query
  with students as (
    select p.id
    from public.profiles p
    where p.role::text = 'student'
      and (p_year is null or p.academic_year = p_year)
      and (p_semester is null or p.academic_semester = p_semester)
      and (p_university_id is null or p.university_id = p_university_id)
  ),
  agg as (
    select a.topic_id,
           count(distinct a.user_id) as students,
           count(*) as answered,
           count(*) filter (where a.is_correct) as correct,
           count(distinct a.question_id) filter (where q.id is not null) as questions_answered
    from public.test_history_answers a
    join students s on s.id = a.user_id
    left join public.questions q
      on q.id = a.question_id and q.topic_id = a.topic_id and q.status::text = 'published'
    where a.course_id = p_course_id
      and (p_from is null or a.completed_at >= p_from)
      and (p_to is null or a.completed_at < p_to)
    group by a.topic_id
  ),
  published as (
    select q.topic_id, count(*) as n
    from public.questions q
    where q.course_id = p_course_id and q.status::text = 'published'
    group by q.topic_id
  )
  select t.id, t.topic_name, t.sort_order, t.is_active,
         coalesce(agg.students, 0), coalesce(agg.answered, 0), coalesce(agg.correct, 0),
         coalesce(agg.questions_answered, 0), coalesce(pub.n, 0)
  from public.course_topics t
  left join agg on agg.topic_id = t.id
  left join published pub on pub.topic_id = t.id
  where t.course_id = p_course_id
    and (agg.topic_id is not null or coalesce(pub.n, 0) > 0)
  order by t.sort_order nulls last, t.topic_name;
end;
$$;

create or replace function public.admin_results_student(
  p_user_id uuid,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  if not private.admin_has_area('people') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles p where p.id = p_user_id) then
    return null;
  end if;

  with ans as (
    select a.*
    from public.test_history_answers a
    where a.user_id = p_user_id
      and (p_from is null or a.completed_at >= p_from)
      and (p_to is null or a.completed_at < p_to)
  ),
  hist as (
    select h.id, h.course_id, h.session_name, h.mode, h.source, h.question_count,
           h.duration_minutes, h.elapsed_seconds, h.created_at,
           coalesce(h.completed_at, h.updated_at) as finished_at
    from public.test_history_entries h
    where h.user_id = p_user_id
      and h.status = 'completed'
      and (p_from is null or coalesce(h.completed_at, h.updated_at) >= p_from)
      and (p_to is null or coalesce(h.completed_at, h.updated_at) < p_to)
  ),
  per_test as (
    select a.history_id,
           count(*) as answered,
           count(*) filter (where a.is_correct) as correct,
           min(a.client) as client
    from ans a
    group by a.history_id
  )
  select jsonb_build_object(
    'profile', (
      select jsonb_build_object(
        'id', p.id,
        'full_name', p.full_name,
        'email', p.email,
        'phone', p.phone,
        'role', p.role::text,
        'approved', p.approved,
        'mcq_access_enabled', p.mcq_access_enabled,
        'courses_access_enabled', p.courses_access_enabled,
        'public_user_id', p.public_user_id,
        'academic_year', p.academic_year,
        'academic_semester', p.academic_semester,
        'university_id', p.university_id,
        'university_name', un.name,
        'college', p.college,
        'created_at', p.created_at
      )
      from public.profiles p
      left join public.universities un on un.id = p.university_id
      where p.id = p_user_id
    ),
    'totals', (
      select jsonb_build_object(
        'tests', (select count(*) from hist),
        'answered', count(*),
        'correct', count(*) filter (where a.is_correct),
        'questions_seen', count(distinct a.question_id),
        'flagged', count(*) filter (where a.flagged),
        'avg_time_sec', round(avg(a.time_spent_sec))
      )
      from ans a
    ),
    'activity', (
      select jsonb_build_object(
        'last_visit_at', (select max(u.last_seen_at) from public.user_activity_sessions u where u.user_id = p_user_id),
        'last_presence_at', (select max(pr.last_seen_at) from public.user_presence pr where pr.user_id = p_user_id),
        'last_route', (
          select pr.current_route from public.user_presence pr
          where pr.user_id = p_user_id
          order by pr.last_seen_at desc nulls last limit 1
        ),
        'visits_30d', (
          select count(*) from public.user_activity_sessions u
          where u.user_id = p_user_id and u.last_seen_at > now() - interval '30 days'
        ),
        'page_views_30d', (
          select coalesce(sum(u.page_views), 0) from public.user_activity_sessions u
          where u.user_id = p_user_id and u.last_seen_at > now() - interval '30 days'
        ),
        'last_block_at', (select max(b.updated_at) from public.test_blocks b where b.user_id = p_user_id)
      )
    ),
    'enrolled_course_ids', (
      select coalesce(jsonb_agg(e.course_id order by e.assigned_at), '[]'::jsonb)
      from public.user_course_enrollments e
      where e.user_id = p_user_id
    ),
    'courses', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'course_id', x.course_id,
        'course_name', coalesce(c.course_name, x.course_name),
        'tests', x.tests,
        'answered', x.answered,
        'correct', x.correct,
        'questions_answered', x.questions_answered,
        'published_questions', (
          select count(*) from public.questions q
          where q.course_id = x.course_id and q.status::text = 'published'
        ),
        'last_answered_at', x.last_answered_at
      ) order by x.answered desc), '[]'::jsonb)
      from (
        select a.course_id,
               max(a.course_name) as course_name,
               count(distinct a.history_id) as tests,
               count(*) as answered,
               count(*) filter (where a.is_correct) as correct,
               count(distinct a.question_id) filter (where q.id is not null) as questions_answered,
               max(a.completed_at) as last_answered_at
        from ans a
        left join public.questions q
          on q.id = a.question_id and q.course_id = a.course_id and q.status::text = 'published'
        where a.course_id is not null
        group by a.course_id
      ) as x
      left join public.courses c on c.id = x.course_id
    ),
    'topics', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'course_id', x.course_id,
        'topic_id', x.topic_id,
        'topic_name', coalesce(t.topic_name, x.topic_name),
        'answered', x.answered,
        'correct', x.correct,
        'questions_answered', x.questions_answered
      ) order by x.course_id, x.correct::numeric / x.answered, x.answered desc), '[]'::jsonb)
      from (
        select a.course_id, a.topic_id,
               max(a.topic_name) as topic_name,
               count(*) as answered,
               count(*) filter (where a.is_correct) as correct,
               count(distinct a.question_id) as questions_answered
        from ans a
        where a.course_id is not null
        group by a.course_id, a.topic_id
      ) as x
      left join public.course_topics t on t.id = x.topic_id
    ),
    'tests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', h.id,
        'course_id', h.course_id,
        'course_name', c.course_name,
        'name', h.session_name,
        'mode', h.mode,
        'source', h.source,
        'question_count', h.question_count,
        'duration_minutes', h.duration_minutes,
        'elapsed_seconds', h.elapsed_seconds,
        'created_at', h.created_at,
        'finished_at', h.finished_at,
        'answered', coalesce(pt.answered, 0),
        'correct', coalesce(pt.correct, 0),
        'client', pt.client
      ) order by h.finished_at desc), '[]'::jsonb)
      from (select * from hist order by finished_at desc limit 200) as h
      left join per_test pt on pt.history_id = h.id
      left join public.courses c on c.id = h.course_id
    ),
    'unfinished', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id,
        'course_id', b.course_id,
        'course_name', c.course_name,
        'status', b.status::text,
        'mode', b.mode::text,
        'question_count', b.question_count,
        'current_index', b.current_index,
        'answered', (
          select count(*) from public.test_responses r
          where r.block_id = b.id and cardinality(r.selected_choice_labels) > 0
        ),
        'created_at', b.created_at,
        'updated_at', b.updated_at
      ) order by b.updated_at desc), '[]'::jsonb)
      from (
        select * from public.test_blocks b0
        where b0.user_id = p_user_id and b0.status::text in ('in_progress', 'suspended')
        order by b0.updated_at desc
        limit 50
      ) as b
      left join public.courses c on c.id = b.course_id
    ),
    'mistakes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'history_id', m.history_id,
        'question_id', m.question_id,
        'stem', left(q.stem, 300),
        'course_id', m.course_id,
        'topic_id', m.topic_id,
        'topic_name', coalesce(t.topic_name, m.topic_name),
        'selected', to_jsonb(m.selected_labels),
        'correct', to_jsonb(m.correct_labels),
        'completed_at', m.completed_at
      ) order by m.completed_at desc), '[]'::jsonb)
      from (
        select * from ans a
        where not a.is_correct
        order by a.completed_at desc
        limit 300
      ) as m
      left join public.questions q on q.id = m.question_id
      left join public.course_topics t on t.id = m.topic_id
    )
  )
  into result;

  return result;
end;
$$;
