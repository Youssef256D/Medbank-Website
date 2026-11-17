-- A reported question disappears from students at once.
--
-- The first open report on a published question turns it into a draft, so
-- no other student meets it until an admin has looked. The question is
-- remembered in `private.question_report_holds`, so closing the reports
-- ("Mark fixed" or "It's correct") publishes exactly those questions again
-- and never one an admin drafted on purpose. Drafting bumps the content
-- version through the existing questions triggers, so the app drops it on
-- its next sync. Students still edit their own open report on a hidden
-- question.
--
-- Questions already reported and still open are hidden now as well.
-- Withdrawing the last open report publishes the question again.

create table if not exists private.question_report_holds (
  question_id uuid primary key references public.questions (id) on delete cascade,
  held_at timestamptz not null default now()
);

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

  select id into existing_id
  from public.question_reports
  where question_id = p_question_id and reporter_id = actor and status = 'open';

  -- A question hidden by reports is a draft; its reporters can still edit
  -- their own report, nobody else can see it to report it.
  select * into q from public.questions where id = p_question_id;
  if not found
     or not (q.status = 'published'
             or (existing_id is not null and q.status = 'draft'))
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

  -- Hide the question from every student until an admin revises it.
  if q.status = 'published' then
    insert into private.question_report_holds (question_id)
    values (p_question_id)
    on conflict (question_id) do nothing;
    update public.questions set status = 'draft' where id = p_question_id;
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

  -- Revised (fixed) or confirmed correct: students see it again, unless an
  -- admin archived it or published it themselves in the meantime.
  update public.questions q
  set status = 'published'
  from private.question_report_holds h
  where h.question_id = p_question_id
    and q.id = h.question_id
    and q.status = 'draft';
  delete from private.question_report_holds where question_id = p_question_id;

  return closed;
end;
$$;


-- A student who withdraws the last open report on a hidden question brings
-- it back: with no open report it would be hidden and missing from the queue.
create or replace function private.release_question_report_hold()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if old.status = 'open'
     and exists (select 1 from private.question_report_holds h where h.question_id = old.question_id)
     and not exists (
       select 1 from public.question_reports r
       where r.question_id = old.question_id and r.status = 'open'
     ) then
    update public.questions set status = 'published'
    where id = old.question_id and status = 'draft';
    delete from private.question_report_holds where question_id = old.question_id;
  end if;
  return old;
end;
$$;

drop trigger if exists trg_question_reports_release_hold on public.question_reports;
create trigger trg_question_reports_release_hold
  after delete on public.question_reports
  for each row execute function private.release_question_report_hold();

insert into private.question_report_holds (question_id)
select distinct r.question_id
from public.question_reports r
join public.questions q on q.id = r.question_id
where r.status = 'open' and q.status = 'published'
on conflict (question_id) do nothing;

update public.questions q
set status = 'draft'
from private.question_report_holds h
where q.id = h.question_id and q.status = 'published';
