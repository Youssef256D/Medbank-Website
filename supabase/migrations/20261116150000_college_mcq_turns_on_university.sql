-- Two admin fixes for colleges with their own MCQ subjects.
--
-- 1. Offering MCQ on a college turns its university's MCQ Bank on too.
--    A student needs both switches, and admins kept turning a college on and
--    then wondering why nobody got access. Turning the university on runs its
--    own trigger (sync_university_mcq_availability), which gives access to the
--    students of every college there that offers MCQ. Turning a college off
--    never turns the university off.
--
-- 2. get_admin_question_count_summary counted questions by subject NAME across
--    every college, so a new "Cardiology" at AASTMT showed the 754 questions
--    of October 6's "Cardiology". It now takes the college (program) to count;
--    with no argument it counts everything, as before, for older builds.

-- ----------------------------------------------------------------------------
-- 1. College MCQ on => university MCQ on
-- ----------------------------------------------------------------------------

create or replace function private.sync_program_mcq_availability()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  univ_has_mcq boolean;
  old_mcq boolean := false;
  old_active boolean := false;
  was_eligible boolean;
  now_eligible boolean;
  auto_mcq boolean;
begin
  if tg_op = 'UPDATE' then
    if (new.mcq_bank_available is not distinct from old.mcq_bank_available)
       and (new.is_active is not distinct from old.is_active) then
      return new;
    end if;
    old_mcq := coalesce(old.mcq_bank_available, false);
    old_active := coalesce(old.is_active, false);
  end if;

  select u.mcq_bank_available
    into univ_has_mcq
  from public.universities u
  where u.id = new.university_id;
  univ_has_mcq := coalesce(univ_has_mcq, false);

  -- Offering MCQ on a college offers it at the university. Its trigger then
  -- activates every eligible student there, this college's included.
  if new.mcq_bank_available is true and not old_mcq and not univ_has_mcq then
    update public.universities
    set mcq_bank_available = true
    where id = new.university_id;
    return new;
  end if;

  was_eligible := univ_has_mcq and old_active and old_mcq;
  now_eligible := univ_has_mcq and coalesce(new.is_active, false)
    and coalesce(new.mcq_bank_available, false);

  if was_eligible is distinct from now_eligible then
    if now_eligible then
      auto_mcq := coalesce(private.is_app_feature_enabled('student_auto_mcq_access'), true);
      update public.profiles p
      set
        mcq_access_enabled = auto_mcq,
        mcq_access_held_at = case when auto_mcq then null else now() end
      where p.university_id = new.university_id
        and lower(trim(coalesce(p.college, ''))) = new.college_key
        and p.role = 'student'::public.app_user_role;
    else
      update public.profiles p
      set
        mcq_access_enabled = false,
        mcq_access_held_at = null
      where p.university_id = new.university_id
        and lower(trim(coalesce(p.college, ''))) = new.college_key
        and p.role = 'student'::public.app_user_role;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_program_mcq_availability()
  from public, anon, authenticated;

-- A college added with MCQ already on counts too.
drop trigger if exists trg_university_colleges_sync_mcq on public.university_colleges;
create trigger trg_university_colleges_sync_mcq
  after insert or update of mcq_bank_available, is_active on public.university_colleges
  for each row execute function private.sync_program_mcq_availability();

-- ----------------------------------------------------------------------------
-- 2. Question counts per college
-- ----------------------------------------------------------------------------

drop function if exists public.get_admin_question_count_summary();

create or replace function public.get_admin_question_count_summary(
  p_program_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  summary jsonb;
begin
  if not private.is_admin_user() then
    raise exception 'Only admins can read question count summaries.'
      using errcode = '42501';
  end if;

  with question_base as (
    select
      q.id,
      q.status::text as status,
      q.created_at,
      coalesce(nullif(trim(c.course_name), ''), '(No course)') as course_name,
      coalesce(nullif(trim(ct.topic_name), ''), '(No topic)') as topic_name,
      exists (
        select 1 from public.question_choices qc where qc.question_id = q.id
      ) as has_choices,
      exists (
        select 1 from public.question_choices qc
        where qc.question_id = q.id and qc.is_correct
      ) as has_correct
    from public.questions q
    left join public.courses c on c.id = q.course_id
    left join public.course_topics ct on ct.id = q.topic_id
    where p_program_id is null or c.program_id = p_program_id
  ),
  totals as (
    select
      count(*)::int as total,
      count(*) filter (where status = 'published')::int as published,
      count(*) filter (where status = 'published' and has_choices and has_correct)::int as published_usable,
      count(*) filter (where status = 'published' and not (has_choices and has_correct))::int as published_unusable,
      count(*) filter (where status = 'draft')::int as draft,
      count(*) filter (where status = 'archived')::int as archived,
      max(created_at) as latest_question_at
    from question_base
  ),
  course_counts as (
    select
      course_name,
      count(*)::int as total,
      count(*) filter (where status = 'published')::int as published,
      count(*) filter (where status = 'published' and has_choices and has_correct)::int as published_usable,
      count(*) filter (where status = 'published' and not (has_choices and has_correct))::int as published_unusable,
      count(*) filter (where status = 'draft')::int as draft,
      count(*) filter (where status = 'archived')::int as archived
    from question_base
    group by course_name
  ),
  topic_counts as (
    select
      course_name,
      topic_name,
      count(*)::int as total,
      count(*) filter (where status = 'published')::int as published,
      count(*) filter (where status = 'published' and has_choices and has_correct)::int as published_usable,
      count(*) filter (where status = 'published' and not (has_choices and has_correct))::int as published_unusable,
      count(*) filter (where status = 'draft')::int as draft,
      count(*) filter (where status = 'archived')::int as archived
    from question_base
    group by course_name, topic_name
  )
  select jsonb_build_object(
    'generatedAt', now(),
    'programId', p_program_id,
    'totals', coalesce((select to_jsonb(t) from totals t), '{}'::jsonb),
    'byCourse', coalesce((
      select jsonb_agg(to_jsonb(cc) order by cc.published_usable desc, cc.total desc, cc.course_name)
      from course_counts cc
    ), '[]'::jsonb),
    'byTopic', coalesce((
      select jsonb_agg(to_jsonb(tc) order by tc.course_name, tc.published_usable desc, tc.total desc, tc.topic_name)
      from topic_counts tc
    ), '[]'::jsonb)
  )
  into summary;

  return summary;
end;
$function$;

revoke all on function public.get_admin_question_count_summary(uuid) from public, anon;
grant execute on function public.get_admin_question_count_summary(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
