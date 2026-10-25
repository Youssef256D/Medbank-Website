-- Admin "Student results" (phase 1): a flat copy of every answered question
-- in every finished test, and admin-only summary functions over it.
--
-- Finished tests from the website and the Flutter app are both stored in
-- test_history_entries, with the answers inside the JSON payload
-- (responses{key:{selected[],flagged,timeSpentSec}} and
-- questionSnapshots{key:{dbId,correct[],topic,course}}). Adding those up
-- from JSON takes minutes, so a trigger copies each finished test's answered
-- questions into test_history_answers when the test is saved, and the admin
-- pages read only that table.
--
-- Access: test_history_answers is a new table. Only admins with the People
-- area can read it (and the functions below); nobody writes to it except the
-- trigger. No existing table, policy or access flag changes.
--
-- Rows are kept when a test_history_entries row is deleted (there is no
-- foreign key to it), so a future clean-up of old tests does not wipe the
-- results. Deleting the student's profile deletes their rows.

create table if not exists public.test_history_answers (
  history_id uuid not null,
  question_key text not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  question_id uuid,
  course_id uuid,
  topic_id uuid,
  course_name text,
  topic_name text,
  selected_labels text[] not null default '{}',
  correct_labels text[] not null default '{}',
  is_correct boolean not null,
  flagged boolean not null default false,
  time_spent_sec integer,
  client text not null check (client in ('website', 'app')),
  completed_at timestamptz not null,
  primary key (history_id, question_key)
);

comment on table public.test_history_answers is
  'One row per answered question per finished test, copied from test_history_entries.payload by trigger. Read by the admin Student results pages.';

create index if not exists idx_test_history_answers_user_completed
  on public.test_history_answers (user_id, completed_at desc);
create index if not exists idx_test_history_answers_question
  on public.test_history_answers (question_id);
create index if not exists idx_test_history_answers_course_topic
  on public.test_history_answers (course_id, topic_id);
create index if not exists idx_test_history_answers_completed
  on public.test_history_answers (completed_at);

alter table public.test_history_answers enable row level security;

revoke all on table public.test_history_answers from anon, authenticated;
grant select on table public.test_history_answers to authenticated;

drop policy if exists test_history_answers_admin_select on public.test_history_answers;
create policy test_history_answers_admin_select
  on public.test_history_answers
  for select
  to authenticated
  using ((select private.admin_has_area('people')));

create or replace function private.results_try_uuid(value text)
returns uuid
language sql
immutable
set search_path to ''
as $$
  select case
    when value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then value::uuid
  end;
$$;

-- Choice labels from a JSON array (or a single string), upper-cased,
-- de-duplicated and sorted so two sets compare with "=".
create or replace function private.results_label_set(value jsonb)
returns text[]
language sql
immutable
set search_path to ''
as $$
  select coalesce(array(
    select distinct upper(btrim(x))
    from jsonb_array_elements_text(
      case jsonb_typeof(value)
        when 'array' then value
        when 'string' then jsonb_build_array(value)
        else '[]'::jsonb
      end
    ) as x
    where btrim(x) <> ''
    order by 1
  ), '{}');
$$;

-- Rebuilds the rows for one finished test. Returns how many were written.
create or replace function private.refresh_test_history_answers(p_history_id uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_entry record;
  v_responses jsonb;
  v_snapshots jsonb;
  v_client text;
  v_written integer := 0;
begin
  delete from public.test_history_answers where history_id = p_history_id;

  select h.id, h.user_id, h.course_id, h.status, h.payload,
         coalesce(h.completed_at, h.updated_at, h.created_at) as finished_at
    into v_entry
  from public.test_history_entries h
  join public.profiles p on p.id = h.user_id
  where h.id = p_history_id;

  if not found or v_entry.status is distinct from 'completed' then
    return 0;
  end if;

  -- Read the payload once; every lookup below uses these copies.
  v_responses := case when jsonb_typeof(v_entry.payload -> 'responses') = 'object'
    then v_entry.payload -> 'responses' else '{}'::jsonb end;
  v_snapshots := case when jsonb_typeof(v_entry.payload -> 'questionSnapshots') = 'object'
    then v_entry.payload -> 'questionSnapshots' else '{}'::jsonb end;
  -- The website writes originSessionId into every payload; the app never does.
  v_client := case when v_entry.payload ? 'originSessionId' then 'website' else 'app' end;

  insert into public.test_history_answers (
    history_id, question_key, user_id, question_id, course_id, topic_id,
    course_name, topic_name, selected_labels, correct_labels, is_correct,
    flagged, time_spent_sec, client, completed_at
  )
  select
    v_entry.id,
    r.key,
    v_entry.user_id,
    coalesce(q.id, private.results_try_uuid(snap.value ->> 'dbId'), private.results_try_uuid(r.key)),
    coalesce(q.course_id, v_entry.course_id),
    q.topic_id,
    nullif(btrim(coalesce(snap.value ->> 'course', snap.value ->> 'qbankCourse', '')), ''),
    nullif(btrim(coalesce(snap.value ->> 'topic', snap.value ->> 'qbankTopic', '')), ''),
    sel.labels,
    cor.labels,
    cardinality(cor.labels) > 0 and sel.labels = cor.labels,
    coalesce(r.value -> 'flagged' = 'true'::jsonb, false),
    case
      when jsonb_typeof(r.value -> 'timeSpentSec') = 'number'
       and (r.value ->> 'timeSpentSec')::numeric between 0 and 3600
        then round((r.value ->> 'timeSpentSec')::numeric)::integer
    end,
    v_client,
    v_entry.finished_at
  from jsonb_each(v_responses) as r (key, value)
  cross join lateral (select v_snapshots -> r.key as value) as snap
  cross join lateral (select private.results_label_set(r.value -> 'selected') as labels) as sel
  left join lateral (
    select m.id, m.course_id, m.topic_id
    from (
      select q1.id, q1.course_id, q1.topic_id, 1 as rank
      from public.questions q1
      where q1.id = private.results_try_uuid(snap.value ->> 'dbId')
      union all
      select q2.id, q2.course_id, q2.topic_id, 2
      from public.questions q2
      where q2.id = private.results_try_uuid(r.key)
      union all
      select q3.id, q3.course_id, q3.topic_id, 3
      from public.questions q3
      where q3.external_id = r.key
    ) as m
    order by m.rank
    limit 1
  ) as q on true
  -- The answer key the student saw; the current one only when the test kept no copy.
  cross join lateral (
    select coalesce(
      nullif(private.results_label_set(snap.value -> 'correct'), '{}'),
      coalesce(array(
        select distinct upper(btrim(c.choice_label))
        from public.question_choices c
        where c.question_id = q.id and c.is_correct
        order by 1
      ), '{}')
    ) as labels
  ) as cor
  where jsonb_typeof(r.value) = 'object'
    and cardinality(sel.labels) > 0;

  get diagnostics v_written = row_count;
  return v_written;
end;
$$;

revoke all on function private.refresh_test_history_answers(uuid) from public, anon, authenticated;

-- Never let a problem here stop a student's test from saving.
create or replace function private.test_history_answers_sync()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  begin
    perform private.refresh_test_history_answers(new.id);
  exception when others then
    raise warning 'test_history_answers refresh failed for %: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function private.test_history_answers_sync() from public, anon, authenticated;

drop trigger if exists trg_test_history_answers_insert on public.test_history_entries;
create trigger trg_test_history_answers_insert
  after insert on public.test_history_entries
  for each row
  execute function private.test_history_answers_sync();

drop trigger if exists trg_test_history_answers_update on public.test_history_entries;
create trigger trg_test_history_answers_update
  after update on public.test_history_entries
  for each row
  when (
    old.payload is distinct from new.payload
    or old.status is distinct from new.status
    or old.user_id is distinct from new.user_id
    or old.course_id is distinct from new.course_id
    or old.completed_at is distinct from new.completed_at
  )
  execute function private.test_history_answers_sync();

-- ---------------------------------------------------------------------------
-- Admin read functions. All of them: People area only, students only (role
-- 'student'), optional filters by finish date (p_from inclusive, p_to
-- exclusive), academic year/semester and university.
-- ---------------------------------------------------------------------------

create or replace function public.admin_results_overview(
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_year smallint default null,
  p_semester smallint default null,
  p_university_id uuid default null,
  p_tz text default 'Africa/Cairo'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_tz text;
  v_series_to timestamptz := coalesce(p_to, now());
  v_series_from timestamptz;
  v_today timestamptz;
  result jsonb;
begin
  if not private.admin_has_area('people') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  v_tz := coalesce((select name from pg_catalog.pg_timezone_names where name = p_tz), 'UTC');
  v_series_from := greatest(coalesce(p_from, v_series_to - interval '30 days'), v_series_to - interval '366 days');
  v_today := date_trunc('day', now() at time zone v_tz) at time zone v_tz;

  with students as (
    select p.id
    from public.profiles p
    where p.role::text = 'student'
      and (p_year is null or p.academic_year = p_year)
      and (p_semester is null or p.academic_semester = p_semester)
      and (p_university_id is null or p.university_id = p_university_id)
  ),
  hist as (
    select h.id, h.user_id, h.question_count, coalesce(h.completed_at, h.updated_at) as finished_at
    from public.test_history_entries h
    join students s on s.id = h.user_id
    where h.status = 'completed'
  ),
  ans as (
    select a.history_id, a.user_id, a.question_id, a.is_correct, a.client, a.completed_at
    from public.test_history_answers a
    join students s on s.id = a.user_id
  ),
  act as (
    select x.user_id, x.at
    from (
      select u.user_id, u.last_seen_at as at
      from public.user_activity_sessions u
      where u.last_seen_at > now() - interval '30 days'
      union all
      select b.user_id, b.updated_at
      from public.test_blocks b
      where b.updated_at > now() - interval '30 days'
      union all
      select h.user_id, h.finished_at
      from hist h
      where h.finished_at > now() - interval '30 days'
    ) as x
    join students s on s.id = x.user_id
  ),
  days as (
    select d::date as day
    from generate_series(
      date_trunc('day', v_series_from at time zone v_tz),
      date_trunc('day', v_series_to at time zone v_tz),
      interval '1 day'
    ) as d
  ),
  hist_days as (
    select (h.finished_at at time zone v_tz)::date as day,
           count(*) as tests,
           count(distinct h.user_id) as students
    from hist h
    where h.finished_at >= v_series_from and h.finished_at < v_series_to
    group by 1
  ),
  ans_days as (
    select (a.completed_at at time zone v_tz)::date as day,
           count(*) as answered,
           count(*) filter (where a.is_correct) as correct,
           count(distinct a.history_id) filter (where a.client = 'website') as website_tests,
           count(distinct a.history_id) filter (where a.client = 'app') as app_tests
    from ans a
    where a.completed_at >= v_series_from and a.completed_at < v_series_to
    group by 1
  )
  select jsonb_build_object(
    'generated_at', now(),
    'timezone', v_tz,
    'tests', (
      select jsonb_build_object(
        'tests', count(*),
        'students', count(distinct h.user_id),
        'questions', coalesce(sum(h.question_count), 0)
      )
      from hist h
      where (p_from is null or h.finished_at >= p_from)
        and (p_to is null or h.finished_at < p_to)
    ),
    'answers', (
      select jsonb_build_object(
        'answered', count(*),
        'correct', count(*) filter (where a.is_correct),
        'questions_seen', count(distinct a.question_id),
        'website_tests', count(distinct a.history_id) filter (where a.client = 'website'),
        'app_tests', count(distinct a.history_id) filter (where a.client = 'app')
      )
      from ans a
      where (p_from is null or a.completed_at >= p_from)
        and (p_to is null or a.completed_at < p_to)
    ),
    'active', (
      select jsonb_build_object(
        'today', count(distinct a.user_id) filter (where a.at >= v_today),
        'week', count(distinct a.user_id) filter (where a.at >= now() - interval '7 days'),
        'month', count(distinct a.user_id)
      )
      from act a
    ),
    'unfinished', (
      select jsonb_build_object(
        'tests', count(*),
        'students', count(distinct b.user_id)
      )
      from public.test_blocks b
      join students s on s.id = b.user_id
      where b.status::text in ('in_progress', 'suspended')
        and b.updated_at > now() - interval '30 days'
    ),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'day', d.day,
        'tests', coalesce(hd.tests, 0),
        'students', coalesce(hd.students, 0),
        'answered', coalesce(ad.answered, 0),
        'correct', coalesce(ad.correct, 0),
        'website_tests', coalesce(ad.website_tests, 0),
        'app_tests', coalesce(ad.app_tests, 0)
      ) order by d.day), '[]'::jsonb)
      from days d
      left join hist_days hd on hd.day = d.day
      left join ans_days ad on ad.day = d.day
    )
  )
  into result;

  return result;
end;
$$;

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
           count(distinct a.question_id) as questions_answered,
           max(a.completed_at) as last_answered_at
    from public.test_history_answers a
    join students s on s.id = a.user_id
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
           count(distinct a.question_id) as questions_answered
    from public.test_history_answers a
    join students s on s.id = a.user_id
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

create or replace function public.admin_results_missed_questions(
  p_course_id uuid default null,
  p_topic_id uuid default null,
  p_min_attempts integer default 10,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_year smallint default null,
  p_semester smallint default null,
  p_university_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  question_id uuid,
  stem text,
  status text,
  course_id uuid,
  course_name text,
  topic_id uuid,
  topic_name text,
  attempts bigint,
  wrong bigint,
  students bigint,
  correct_labels text[],
  choice_counts jsonb,
  open_reports bigint,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_min integer := greatest(coalesce(p_min_attempts, 10), 1);
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
  ans as (
    select a.question_id, a.user_id, a.is_correct, a.selected_labels
    from public.test_history_answers a
    join students s on s.id = a.user_id
    where a.question_id is not null
      and (p_course_id is null or a.course_id = p_course_id)
      and (p_topic_id is null or a.topic_id = p_topic_id)
      and (p_from is null or a.completed_at >= p_from)
      and (p_to is null or a.completed_at < p_to)
  ),
  agg as (
    select a.question_id,
           count(*) as attempts,
           count(*) filter (where not a.is_correct) as wrong,
           count(distinct a.user_id) as students
    from ans a
    group by a.question_id
    having count(*) >= v_min
  ),
  page as (
    select agg.*, count(*) over () as total_count
    from agg
    order by agg.wrong::numeric / agg.attempts desc, agg.attempts desc, agg.question_id
    limit v_limit offset v_offset
  )
  select pg.question_id,
         left(q.stem, 400),
         q.status::text,
         q.course_id,
         c.course_name,
         q.topic_id,
         t.topic_name,
         pg.attempts,
         pg.wrong,
         pg.students,
         coalesce(array(
           select distinct upper(btrim(ch.choice_label))
           from public.question_choices ch
           where ch.question_id = pg.question_id and ch.is_correct
           order by 1
         ), '{}'),
         (
           select coalesce(jsonb_object_agg(x.label, x.n), '{}'::jsonb)
           from (
             select l as label, count(*) as n
             from ans a2, unnest(a2.selected_labels) as l
             where a2.question_id = pg.question_id
             group by l
           ) as x
         ),
         (
           select count(*)
           from public.question_reports r
           where r.question_id = pg.question_id and r.status = 'open'
         ),
         pg.total_count
  from page pg
  left join public.questions q on q.id = pg.question_id
  left join public.courses c on c.id = q.course_id
  left join public.course_topics t on t.id = q.topic_id
  order by pg.wrong::numeric / pg.attempts desc, pg.attempts desc, pg.question_id;
end;
$$;

create or replace function public.admin_results_students(
  p_search text default null,
  p_sort text default 'last_active',
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_year smallint default null,
  p_semester smallint default null,
  p_university_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  full_name text,
  email text,
  public_user_id bigint,
  academic_year smallint,
  academic_semester smallint,
  university_id uuid,
  university_name text,
  approved boolean,
  tests bigint,
  answered bigint,
  correct bigint,
  last_test_at timestamptz,
  last_seen_at timestamptz,
  unfinished_tests bigint,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(lower(btrim(coalesce(p_search, ''))), '');
  v_sort text := coalesce(p_sort, 'last_active');
begin
  if not private.admin_has_area('people') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  return query
  with students as (
    select p.id, p.full_name, p.email, p.public_user_id, p.academic_year,
           p.academic_semester, p.university_id, p.approved
    from public.profiles p
    where p.role::text = 'student'
      and (p_year is null or p.academic_year = p_year)
      and (p_semester is null or p.academic_semester = p_semester)
      and (p_university_id is null or p.university_id = p_university_id)
      and (
        v_search is null
        or position(v_search in lower(coalesce(p.full_name, ''))) > 0
        or position(v_search in lower(coalesce(p.email, ''))) > 0
        or p.public_user_id::text = v_search
      )
  ),
  hist as (
    select h.user_id, count(*) as tests, max(coalesce(h.completed_at, h.updated_at)) as last_test_at
    from public.test_history_entries h
    join students s on s.id = h.user_id
    where h.status = 'completed'
      and (p_from is null or coalesce(h.completed_at, h.updated_at) >= p_from)
      and (p_to is null or coalesce(h.completed_at, h.updated_at) < p_to)
    group by h.user_id
  ),
  ans as (
    select a.user_id, count(*) as answered, count(*) filter (where a.is_correct) as correct
    from public.test_history_answers a
    join students s on s.id = a.user_id
    where (p_from is null or a.completed_at >= p_from)
      and (p_to is null or a.completed_at < p_to)
    group by a.user_id
  ),
  blocks as (
    select b.user_id,
           count(*) filter (where b.status::text in ('in_progress', 'suspended')) as unfinished,
           max(b.updated_at) as last_block_at
    from public.test_blocks b
    join students s on s.id = b.user_id
    group by b.user_id
  ),
  visits as (
    select u.user_id, max(u.last_seen_at) as last_visit_at
    from public.user_activity_sessions u
    join students s on s.id = u.user_id
    group by u.user_id
  ),
  presence as (
    select pr.user_id, max(pr.last_seen_at) as last_presence_at
    from public.user_presence pr
    join students s on s.id = pr.user_id
    group by pr.user_id
  ),
  listed as (
    select s.id, s.full_name, s.email, s.public_user_id, s.academic_year, s.academic_semester,
           s.university_id, un.name as university_name, s.approved,
           coalesce(hist.tests, 0) as tests,
           coalesce(ans.answered, 0) as answered,
           coalesce(ans.correct, 0) as correct,
           hist.last_test_at,
           nullif(greatest(
             coalesce(hist.last_test_at, '-infinity'::timestamptz),
             coalesce(blocks.last_block_at, '-infinity'::timestamptz),
             coalesce(visits.last_visit_at, '-infinity'::timestamptz),
             coalesce(presence.last_presence_at, '-infinity'::timestamptz)
           ), '-infinity'::timestamptz) as last_seen_at,
           coalesce(blocks.unfinished, 0) as unfinished_tests
    from students s
    left join public.universities un on un.id = s.university_id
    left join hist on hist.user_id = s.id
    left join ans on ans.user_id = s.id
    left join blocks on blocks.user_id = s.id
    left join visits on visits.user_id = s.id
    left join presence on presence.user_id = s.id
  )
  select r.id, r.full_name, r.email, r.public_user_id, r.academic_year, r.academic_semester,
         r.university_id, r.university_name, r.approved, r.tests, r.answered, r.correct,
         r.last_test_at, r.last_seen_at, r.unfinished_tests, count(*) over ()
  from listed r
  order by
    case when v_sort = 'name' then lower(coalesce(r.full_name, r.email, '')) end asc,
    case when v_sort = 'tests' then r.tests end desc,
    case when v_sort = 'answered' then r.answered end desc,
    case when v_sort = 'accuracy' then r.correct::numeric / nullif(r.answered, 0) end desc nulls last,
    case when v_sort = 'accuracy_asc' then r.correct::numeric / nullif(r.answered, 0) end asc nulls last,
    r.last_seen_at desc nulls last,
    r.id
  limit v_limit offset v_offset;
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
               count(distinct a.question_id) as questions_answered,
               max(a.completed_at) as last_answered_at
        from ans a
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

revoke all on function public.admin_results_overview(timestamptz, timestamptz, smallint, smallint, uuid, text) from public, anon;
revoke all on function public.admin_results_subjects(timestamptz, timestamptz, smallint, smallint, uuid) from public, anon;
revoke all on function public.admin_results_topics(uuid, timestamptz, timestamptz, smallint, smallint, uuid) from public, anon;
revoke all on function public.admin_results_missed_questions(uuid, uuid, integer, timestamptz, timestamptz, smallint, smallint, uuid, integer, integer) from public, anon;
revoke all on function public.admin_results_students(text, text, timestamptz, timestamptz, smallint, smallint, uuid, integer, integer) from public, anon;
revoke all on function public.admin_results_student(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_results_overview(timestamptz, timestamptz, smallint, smallint, uuid, text) to authenticated;
grant execute on function public.admin_results_subjects(timestamptz, timestamptz, smallint, smallint, uuid) to authenticated;
grant execute on function public.admin_results_topics(uuid, timestamptz, timestamptz, smallint, smallint, uuid) to authenticated;
grant execute on function public.admin_results_missed_questions(uuid, uuid, integer, timestamptz, timestamptz, smallint, smallint, uuid, integer, integer) to authenticated;
grant execute on function public.admin_results_students(text, text, timestamptz, timestamptz, smallint, smallint, uuid, integer, integer) to authenticated;
grant execute on function public.admin_results_student(uuid, timestamptz, timestamptz) to authenticated;
