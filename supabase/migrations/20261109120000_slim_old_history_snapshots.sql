-- Slim previous tests older than 30 days (owner approved 2026-10-27, plan in
-- docs/test-history-compaction-plan.md).
--
-- Each question snapshot in test_history_entries.payload.questionSnapshots
-- keeps ids, course/topic names, status, difficulty, `correct` and the choice
-- labels; the stem, choice text, explanation and image URLs are dropped.
-- Scores, topic stats, question pools, admin results and
-- test_history_answers only read the kept fields. Review takes the text from
-- the live bank (website: expandSlimQuestionSnapshot; app: da3a966).
--
-- A slimmed row gets payload.snapshotsSlimmedAt and a new updated_at, so
-- clients holding a saved copy fetch the slim one. The dropped text cannot be
-- restored from the database; take a backup first (docs/backup-restore-runbook.md).

create or replace function private.slim_question_snapshot(p_snap jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_snap) is distinct from 'object' or not (p_snap ? 'stem') then p_snap
    else jsonb_strip_nulls(jsonb_build_object(
      'id', p_snap -> 'id',
      'dbId', p_snap -> 'dbId',
      'correct', p_snap -> 'correct',
      'course', p_snap -> 'course',
      'system', p_snap -> 'system',
      'topic', p_snap -> 'topic',
      'qbankCourse', p_snap -> 'qbankCourse',
      'qbankTopic', p_snap -> 'qbankTopic',
      'status', p_snap -> 'status',
      'difficulty', p_snap -> 'difficulty',
      'choices', coalesce((
        select jsonb_agg(jsonb_build_object('id', c -> 'id'))
        from jsonb_array_elements(
          case when jsonb_typeof(p_snap -> 'choices') = 'array' then p_snap -> 'choices' else '[]'::jsonb end
        ) as c
        where jsonb_typeof(c) = 'object'
      ), '[]'::jsonb)
    ))
  end;
$$;

-- Slims up to p_max_rows rows, p_batch at a time, committing after each batch
-- so locks and WAL stay small. No SET clause: a procedure with one cannot
-- commit, so every name is schema-qualified instead.
create or replace procedure private.run_history_slimming(
  p_max_rows integer default 2000,
  p_batch integer default 200,
  p_min_age interval default interval '30 days'
)
language plpgsql
as $$
declare
  v_done integer := 0;
  v_rows integer;
begin
  loop
    with picked as (
      select h.id
      from public.test_history_entries h
      where h.completed_at < pg_catalog.now() - p_min_age
        and not (h.payload ? 'snapshotsSlimmedAt')
        and pg_catalog.jsonb_typeof(h.payload -> 'questionSnapshots') = 'object'
      order by h.completed_at
      limit least(p_batch, p_max_rows - v_done)
      for update skip locked
    )
    update public.test_history_entries h
       set payload = pg_catalog.jsonb_set(
             h.payload,
             '{questionSnapshots}',
             coalesce((
               select pg_catalog.jsonb_object_agg(e.key, private.slim_question_snapshot(e.value))
               from pg_catalog.jsonb_each(h.payload -> 'questionSnapshots') as e
             ), '{}'::jsonb)
           ) || pg_catalog.jsonb_build_object('snapshotsSlimmedAt', pg_catalog.to_jsonb(pg_catalog.now()))
      from picked
     where h.id = picked.id;
    get diagnostics v_rows = row_count;
    v_done := v_done + v_rows;
    commit;
    exit when v_rows = 0 or v_done >= p_max_rows;
  end loop;
  raise notice 'run_history_slimming: % rows slimmed', v_done;
end;
$$;

revoke all on function private.slim_question_snapshot(jsonb) from public, anon, authenticated;
revoke all on procedure private.run_history_slimming(integer, integer, interval) from public, anon, authenticated;

-- Nightly, after the other clean-up jobs. The ~5,300-row backlog clears in
-- about three nights; after that each night slims the tests that turned 30
-- days old.
select cron.schedule(
  'slim-old-history-snapshots',
  '23 4 * * *',
  $$call private.run_history_slimming(2000)$$
);
