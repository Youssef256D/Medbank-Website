-- Students report MCQ Bank questions they think are wrong; admins review them.
--
-- One table, shared by the app and the website. A student has at most one
-- *open* report per question (a partial unique index), so sending again edits
-- that report instead of adding a vote. Once an admin marks the question fixed
-- or dismisses it, those reports are closed and the count starts again from
-- zero: the queue only ever counts open reports.
--
-- Students never write the table directly. `report_question` checks they can
-- see the question, limits them to 30 reports a day, and raises the
-- question's level. When a question first reaches "urgent", every admin who
-- can edit questions gets a notification (and a push). When an admin closes
-- the reports, each reporter is told the outcome — that insert happens in a
-- trigger so `guard_admin_action` (which would ask the admin for the
-- messaging permission) stays out of it.
--
-- Priority is not the raw count alone. A question 2,000 students answered
-- will always collect more reports than one 20 students answered, so the
-- share of the students who answered it counts too
-- (`private.question_report_level`). Minimum counts stop one report out of
-- five answers from looking like 20%.
--
-- Video-course quiz questions are a separate product and are not covered.

create table public.question_reports (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null check (
    reason in (
      'wrong_answer', 'wrong_explanation', 'typo', 'image', 'unclear', 'other'
    )
  ),
  note text check (note is null or char_length(note) <= 1000),
  suggested_choice_label text check (
    suggested_choice_label is null or char_length(suggested_choice_label) <= 4
  ),
  source text not null default 'app' check (source in ('app', 'website')),
  status text not null default 'open' check (
    status in ('open', 'resolved', 'dismissed')
  ),
  resolution_note text check (
    resolution_note is null or char_length(resolution_note) <= 1000
  ),
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index question_reports_one_open_per_student
  on public.question_reports (question_id, reporter_id)
  where status = 'open';
create index question_reports_open_question
  on public.question_reports (question_id)
  where status = 'open';
create index question_reports_reporter_created
  on public.question_reports (reporter_id, created_at desc);

-- How many students answered a question is read once per reported question.
create index if not exists test_responses_question_id_idx
  on public.test_responses (question_id);

alter table public.question_reports enable row level security;

-- Students read their own reports (to show "You reported this"); admins with
-- the MCQ area read all. Writes go through the functions below only, except
-- a student withdrawing their own open report.
create policy question_reports_select on public.question_reports
  for select to authenticated
  using (
    reporter_id = (select auth.uid())
    or (select private.admin_has_area('mcq'))
  );

create policy question_reports_delete_own_open on public.question_reports
  for delete to authenticated
  using (reporter_id = (select auth.uid()) and status = 'open');

revoke all on public.question_reports from anon;
revoke insert, update, truncate on public.question_reports from authenticated;

-- low (1) · watch (2+) · high (5+, or 3% of answerers with 2+)
-- · urgent (10+, or 10% of answerers with 3+).
create or replace function private.question_report_level(
  reporters integer,
  answerers integer
)
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when reporters <= 0 then 'none'
    when reporters >= 10
      or (reporters >= 3 and reporters::numeric / greatest(answerers, 1) >= 0.10)
      then 'urgent'
    when reporters >= 5
      or (reporters >= 2 and reporters::numeric / greatest(answerers, 1) >= 0.03)
      then 'high'
    when reporters >= 2 then 'watch'
    else 'low'
  end;
$$;

create or replace function private.question_answerer_count(target_question_id uuid)
returns integer
language sql
stable
security definer
set search_path to ''
as $$
  select count(distinct b.user_id)::integer
  from public.test_responses r
  join public.test_blocks b on b.id = r.block_id
  where r.question_id = target_question_id
    and coalesce(array_length(r.selected_choice_labels, 1), 0) > 0;
$$;

-- Admins who can edit questions, the people an urgent question is sent to.
create or replace function private.question_report_admin_ids()
returns setof uuid
language sql
stable
security definer
set search_path to ''
as $$
  select p.id
  from public.profiles p
  join public.admin_permissions ap on ap.user_id = p.id
  where p.role = 'admin'
    and p.approved is true
    and (
      ap.is_super
      or (
        'mcq' = any (ap.areas)
        and (ap.permissions is null or 'mcq.questions_edit' = any (ap.permissions))
      )
    );
$$;

create or replace function public.report_question(
  p_question_id uuid,
  p_reason text,
  p_note text default null,
  p_suggested_choice_label text default null,
  p_source text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor uuid := (select auth.uid());
  q public.questions%rowtype;
  existing_id uuid;
  report_id uuid;
  today_count integer;
  reporters_before integer;
  reporters_after integer;
  answerers integer;
  level_before text;
  level_after text;
  first_open timestamptz;
  clean_note text := nullif(btrim(coalesce(p_note, '')), '');
  clean_label text := nullif(upper(btrim(coalesce(p_suggested_choice_label, ''))), '');
begin
  if actor is null then
    raise exception 'Sign in to report a question.' using errcode = '42501';
  end if;
  if not private.can_current_user_access_mcq() then
    raise exception 'Your account cannot open the MCQ Bank.' using errcode = '42501';
  end if;

  select * into q from public.questions where id = p_question_id;
  if not found
     or q.status <> 'published'
     or not (private.is_admin_user()
             or private.can_current_user_access_question(q.course_id, q.topic_id)) then
    raise exception 'Question not found.' using errcode = 'P0002';
  end if;

  if clean_label is not null and not exists (
    select 1 from public.question_choices c
    where c.question_id = p_question_id and upper(c.choice_label) = clean_label
  ) then
    clean_label := null;
  end if;

  select id into existing_id
  from public.question_reports
  where question_id = p_question_id and reporter_id = actor and status = 'open';

  if existing_id is null then
    select count(*) into today_count
    from public.question_reports
    where reporter_id = actor and created_at > now() - interval '24 hours';
    if today_count >= 30 then
      raise exception 'You have sent a lot of reports today. Try again tomorrow.'
        using errcode = 'P0001', hint = 'rate_limited';
    end if;
  end if;

  select count(*) into reporters_before
  from public.question_reports
  where question_id = p_question_id and status = 'open';

  if existing_id is null then
    insert into public.question_reports (
      question_id, reporter_id, reason, note, suggested_choice_label, source
    )
    values (
      p_question_id, actor, p_reason, clean_note, clean_label,
      case when p_source = 'website' then 'website' else 'app' end
    )
    returning id into report_id;
  else
    update public.question_reports
    set reason = p_reason,
        note = clean_note,
        suggested_choice_label = clean_label,
        updated_at = now()
    where id = existing_id
    returning id into report_id;
  end if;

  reporters_after := reporters_before + case when existing_id is null then 1 else 0 end;
  answerers := private.question_answerer_count(p_question_id);
  level_before := private.question_report_level(reporters_before, answerers);
  level_after := private.question_report_level(reporters_after, answerers);

  if level_after = 'urgent' and level_before <> 'urgent' then
    select min(created_at) into first_open
    from public.question_reports
    where question_id = p_question_id and status = 'open';

    -- The alert is best-effort: a failure here never loses the report.
    begin
      insert into public.notifications (
        external_id, recipient_user_id, title, message, created_by_name
      )
      select
        'question-report-urgent::' || p_question_id::text || '::'
          || extract(epoch from first_open)::bigint::text || '::' || admin_id::text,
        admin_id,
        'Urgent: a question needs a look',
        reporters_after || ' students think this question is wrong: "'
          || left(regexp_replace(q.stem, '\s+', ' ', 'g'), 90)
          || case when char_length(q.stem) > 90 then '…' else '' end
          || '". Open Question reports to review it.',
        'MedBank'
      from private.question_report_admin_ids() as admin_id
      where not exists (
        select 1 from public.notifications n
        where n.external_id = 'question-report-urgent::' || p_question_id::text || '::'
          || extract(epoch from first_open)::bigint::text || '::' || admin_id::text
      );
    exception when others then
      raise warning 'question report alert failed: %', sqlerrm;
    end;
  end if;

  return jsonb_build_object(
    'id', report_id,
    'status', case when existing_id is null then 'created' else 'updated' end
  );
end;
$$;

-- The admin queue: one row per question with open reports (or, for
-- p_status 'closed', recently closed ones), most urgent first.
create or replace function public.admin_question_report_queue(
  p_status text default 'open',
  p_level text default null,
  p_limit integer default 50,
  p_offset integer default 0
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
  if not private.admin_has_area('mcq') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  with base as (
    select r.*
    from public.question_reports r
    where (p_status = 'open' and r.status = 'open')
       or (p_status <> 'open' and r.status <> 'open'
           and r.resolved_at > now() - interval '60 days')
  ),
  grouped as (
    select
      b.question_id,
      count(*)::integer as reporters,
      min(b.created_at) as first_reported_at,
      max(b.created_at) as last_reported_at,
      max(b.resolved_at) as closed_at,
      (array_agg(b.status order by b.resolved_at desc nulls last))[1] as closed_status,
      (
        select coalesce(jsonb_object_agg(x.reason, x.n), '{}'::jsonb)
        from (
          select b2.reason, count(*) as n
          from base b2
          where b2.question_id = b.question_id
          group by b2.reason
        ) x
      ) as reasons,
      (
        select coalesce(jsonb_object_agg(y.label, y.n), '{}'::jsonb)
        from (
          select b3.suggested_choice_label as label, count(*) as n
          from base b3
          where b3.question_id = b.question_id
            and b3.suggested_choice_label is not null
          group by b3.suggested_choice_label
        ) y
      ) as labels
    from base b
    group by b.question_id
  ),
  scored as (
    select
      g.*,
      private.question_answerer_count(g.question_id) as answerers
    from grouped g
  ),
  leveled as (
    select
      s.*,
      private.question_report_level(s.reporters, s.answerers) as level,
      round(
        s.reporters
        + least(s.reporters::numeric / greatest(s.answerers, 1), 1) * 50
        + case when s.last_reported_at > now() - interval '48 hours' then 2 else 0 end,
        2
      ) as score
    from scored s
  ),
  filtered as (
    select l.*, count(*) over () as total
    from leveled l
    where p_level is null or l.level = p_level
    order by
      case when p_status = 'open' then
        case l.level when 'urgent' then 4 when 'high' then 3 when 'watch' then 2 else 1 end
      end desc nulls last,
      case when p_status = 'open' then l.score end desc nulls last,
      l.closed_at desc nulls last,
      l.last_reported_at desc
    limit greatest(least(p_limit, 200), 1)
    offset greatest(p_offset, 0)
  )
  select jsonb_build_object(
    'total', coalesce(max(f.total), 0),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'question_id', f.question_id,
      'stem', q.stem,
      'question_status', q.status,
      'course_id', q.course_id,
      'course_name', c.course_name,
      'topic_name', t.topic_name,
      'correct_labels', (
        select coalesce(jsonb_agg(ch.choice_label order by ch.choice_label), '[]'::jsonb)
        from public.question_choices ch
        where ch.question_id = f.question_id and ch.is_correct
      ),
      'reporters', f.reporters,
      'answerers', f.answerers,
      'level', f.level,
      'score', f.score,
      'reasons', f.reasons,
      'suggested_labels', f.labels,
      'first_reported_at', f.first_reported_at,
      'last_reported_at', f.last_reported_at,
      'closed_at', f.closed_at,
      'closed_status', case when p_status = 'open' then null else f.closed_status end
    ) order by
      case when p_status = 'open' then
        case f.level when 'urgent' then 4 when 'high' then 3 when 'watch' then 2 else 1 end
      end desc nulls last,
      case when p_status = 'open' then f.score end desc nulls last,
      f.closed_at desc nulls last,
      f.last_reported_at desc), '[]'::jsonb)
  )
  into result
  from filtered f
  join public.questions q on q.id = f.question_id
  left join public.courses c on c.id = q.course_id
  left join public.course_topics t on t.id = q.topic_id;

  return result;
end;
$$;

-- Counts for the dashboard badge and the page's level chips.
create or replace function public.admin_question_report_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  if not private.admin_has_area('mcq') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  with per_question as (
    select
      r.question_id,
      private.question_report_level(
        count(*)::integer,
        private.question_answerer_count(r.question_id)
      ) as level
    from public.question_reports r
    where r.status = 'open'
    group by r.question_id
  )
  select jsonb_build_object(
    'open', count(*),
    'urgent', count(*) filter (where level = 'urgent'),
    'high', count(*) filter (where level = 'high'),
    'watch', count(*) filter (where level = 'watch'),
    'low', count(*) filter (where level = 'low')
  )
  into result
  from per_question;

  return result;
end;
$$;

-- Every report on one question, newest first, with the reporter's name.
create or replace function public.admin_question_report_details(
  p_question_id uuid,
  p_status text default 'open'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if not private.admin_has_area('mcq') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id,
      'reason', r.reason,
      'note', r.note,
      'suggested_choice_label', r.suggested_choice_label,
      'source', r.source,
      'status', r.status,
      'resolution_note', r.resolution_note,
      'created_at', r.created_at,
      'resolved_at', r.resolved_at,
      'reporter_name', coalesce(nullif(btrim(p.full_name), ''), 'Student'),
      'reporter_public_id', p.public_user_id
    ) order by r.created_at desc)
    from public.question_reports r
    left join public.profiles p on p.id = r.reporter_id
    where r.question_id = p_question_id
      and ((p_status = 'open' and r.status = 'open')
           or (p_status <> 'open' and r.status <> 'open'))
  ), '[]'::jsonb);
end;
$$;

-- Close every open report on a question: 'resolved' (we fixed it) or
-- 'dismissed' (we checked; it is right). Reporters are told by the trigger.
create or replace function public.admin_close_question_reports(
  p_question_id uuid,
  p_status text,
  p_note text default null
)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  closed integer;
begin
  if not private.admin_can('mcq.questions_edit') then
    raise exception 'Your admin account is not allowed to edit questions.'
      using errcode = '42501';
  end if;
  if p_status not in ('resolved', 'dismissed') then
    raise exception 'Unknown status %.', p_status using errcode = '22023';
  end if;

  update public.question_reports
  set status = p_status,
      resolution_note = nullif(btrim(coalesce(p_note, '')), ''),
      resolved_by = (select auth.uid()),
      resolved_at = now(),
      updated_at = now()
  where question_id = p_question_id and status = 'open';

  get diagnostics closed = row_count;
  return closed;
end;
$$;

create or replace function private.notify_question_reporters()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  stem text;
begin
  if old.status <> 'open' or new.status = 'open' then
    return new;
  end if;

  select left(regexp_replace(q.stem, '\s+', ' ', 'g'), 80)
         || case when char_length(q.stem) > 80 then '…' else '' end
    into stem
  from public.questions q
  where q.id = new.question_id;

  insert into public.notifications (
    external_id, recipient_user_id, title, message, created_by_name
  )
  values (
    'question-report-closed::' || new.id::text,
    new.reporter_id,
    case new.status
      when 'resolved' then 'Thanks — we fixed the question you reported'
      else 'We checked the question you reported'
    end,
    case new.status
      when 'resolved' then 'Your report helped: "' || coalesce(stem, '') || '" has been corrected.'
      else '"' || coalesce(stem, '') || '" was reviewed and is correct as written.'
    end
    || case when new.resolution_note is not null
         then ' Note from the team: ' || new.resolution_note
         else '' end,
    'MedBank'
  )
  on conflict do nothing;

  return new;
end;
$$;

create trigger trg_question_reports_notify_reporters
  after update of status on public.question_reports
  for each row execute function private.notify_question_reporters();

revoke all on function public.report_question(uuid, text, text, text, text) from public, anon;
revoke all on function public.admin_question_report_queue(text, text, integer, integer) from public, anon;
revoke all on function public.admin_question_report_summary() from public, anon;
revoke all on function public.admin_question_report_details(uuid, text) from public, anon;
revoke all on function public.admin_close_question_reports(uuid, text, text) from public, anon;
grant execute on function public.report_question(uuid, text, text, text, text) to authenticated;
grant execute on function public.admin_question_report_queue(text, text, integer, integer) to authenticated;
grant execute on function public.admin_question_report_summary() to authenticated;
grant execute on function public.admin_question_report_details(uuid, text) to authenticated;
grant execute on function public.admin_close_question_reports(uuid, text, text) to authenticated;
