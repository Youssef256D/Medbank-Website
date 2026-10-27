-- Assertions for 20261027125000_server_side_grading.sql, run by run-local.sh
-- after stubs.sql and the migration. Any failure raises and stops psql.

\set ON_ERROR_STOP on

-- Fixtures (as superuser).
insert into public.profiles (id, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin'),
  ('00000000-0000-0000-0000-000000000001', 'student'),
  ('00000000-0000-0000-0000-000000000002', 'student');
insert into public.courses values ('10000000-0000-0000-0000-000000000000', 'Gyn');
insert into public.course_topics values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000000', 'Open'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000000', 'Locked');
insert into private.locked_topics values ('20000000-0000-0000-0000-000000000002');

-- q1, q2, q3 published/open; q4 draft; q5 locked topic.
insert into public.questions (id, course_id, topic_id, stem, explanation, explanation_image_url, status) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000001', 'Q1', 'because one', 'https://x/1.png', 'published'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000001', 'Q2', 'because two', null, 'published'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000001', 'Q3', 'because three', null, 'published'),
  ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000001', 'Q4', 'draft', null, 'draft'),
  ('30000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000002', 'Q5', 'locked', null, 'published');
insert into public.question_choices (question_id, choice_label, choice_text, is_correct)
select q.id, l.label, 'opt ' || l.label, l.label = case right(q.id::text, 1) when '1' then 'B' when '2' then 'C' else 'A' end
from public.questions q cross join (values ('A'), ('B'), ('C'), ('D')) as l(label);

-- Student 1: tutor block with q1..q5 (q4/q5 smuggled in), timed block with q1..q3.
insert into public.test_blocks (id, user_id, mode) values
  ('40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'tutor'),
  ('40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'timed'),
  ('40000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002', 'tutor');
insert into public.test_block_items (block_id, position, question_id)
select '40000000-0000-0000-0000-000000000001', n, ('30000000-0000-0000-0000-00000000000' || n)::uuid from generate_series(1, 5) n;
insert into public.test_block_items (block_id, position, question_id)
select '40000000-0000-0000-0000-000000000002', n, ('30000000-0000-0000-0000-00000000000' || n)::uuid from generate_series(1, 3) n;
insert into public.test_block_items values ('40000000-0000-0000-0000-000000000003', 1, '30000000-0000-0000-0000-000000000001');

create schema t;
grant usage on schema t to authenticated;
create function t.check(ok boolean, msg text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', msg; end if;
  raise notice 'ok: %', msg;
end;
$$;
grant execute on function t.check(boolean, text) to authenticated;

-- ---------------------------------------------------------------- switch off
set role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-000000000001', false);

select t.check(
  (select count(*) from public.question_choices where is_correct) = 3,
  'switch off: student still reads is_correct from the table (phase 1 unchanged)');
select t.check(
  (select bool_or((c->>'is_correct')::boolean) from private.get_accessible_question_catalog_page(100, 0) r, jsonb_array_elements(r.choices) c),
  'switch off: catalog still returns is_correct');

-- Unanswered question: no key.
select t.check(
  (select count(*) from public.get_test_answer_key('40000000-0000-0000-0000-000000000001')) = 0,
  'no key before any answer');

-- Tutor submit, wrong answer.
select t.check(
  (select r->>'graded' = 'true' and r->>'is_correct' = 'false'
       and r->'correct_labels' = '["B"]'::jsonb and r->>'explanation' = 'because one'
       and r->>'explanation_image_url' = 'https://x/1.png'
   from public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', array['a']) r),
  'submit_test_answer grades a wrong answer and returns key + explanation');

-- Answers are final: resubmitting a different answer keeps the first.
select t.check(
  (select r->'selected_labels' = '["A"]'::jsonb and r->>'is_correct' = 'false'
   from public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', array['B']) r),
  'second submit keeps the stored answer');
update public.test_responses set selected_choice_labels = array['B'], flagged = true
where block_id = '40000000-0000-0000-0000-000000000001' and question_id = '30000000-0000-0000-0000-000000000001';
select t.check(
  (select selected_choice_labels = array['A'] and submitted and flagged from public.test_responses
   where block_id = '40000000-0000-0000-0000-000000000001' and question_id = '30000000-0000-0000-0000-000000000001'),
  'direct table update cannot change a solved answer, flag still updates');

-- Correct answer, label checks.
select t.check(
  (select r->>'is_correct' = 'true'
   from public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', array[' c ', 'Z']) r),
  'labels are trimmed/upper-cased, unknown labels dropped, correct answer graded');
select t.check(
  (select r->>'submitted' = 'false' and r->>'graded' = 'false'
   from public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', array['Z']) r),
  'empty selection is not stored as submitted and gets no key');

-- Draft / locked questions smuggled into a block: refused.
do $$ begin
  perform public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', array['A']);
  raise exception 'FAILED: draft question was accepted';
exception when insufficient_privilege then raise notice 'ok: draft question refused'; end $$;
do $$ begin
  perform public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000005', array['A']);
  raise exception 'FAILED: locked question was accepted';
exception when insufficient_privilege then raise notice 'ok: locked question refused'; end $$;

-- Question not in the block.
do $$ begin
  perform public.submit_test_answer('40000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000001', array['A']);
  raise exception 'FAILED: another student''s block was accepted';
exception when insufficient_privilege then raise notice 'ok: another student''s block refused'; end $$;

-- Answered via the table (website/app sync path) then key fetched.
insert into public.test_responses (block_id, question_id, selected_choice_labels, submitted)
values ('40000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000003', array['A'], true);
select t.check(
  (select array_agg(question_id::text order by question_id) = array['30000000-0000-0000-0000-000000000003']
   from public.get_test_answer_key('40000000-0000-0000-0000-000000000002')),
  'unfinished block: key only for the solved question');

-- Finished block: keys for all its questions, but never for draft/locked ones.
update public.test_blocks set status = 'completed' where id = '40000000-0000-0000-0000-000000000001';
select t.check(
  (select array_agg(right(question_id::text, 1) order by question_id) = array['1', '2', '3']
   from public.get_test_answer_key('40000000-0000-0000-0000-000000000001') where not capped),
  'finished block: keys for skipped questions too, not for draft/locked');
select t.check(
  (select count(*) = 1 from public.get_test_answer_key('40000000-0000-0000-0000-000000000001', array['30000000-0000-0000-0000-000000000003'::uuid])),
  'p_question_ids narrows the result');
select t.check(
  (select r->>'graded' = 'true' and r->>'submitted' = 'false'
   from public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', array['A']) r),
  'finished block takes no new answer but returns the key');

-- No MCQ access: refused.
select set_config('test.no_mcq', 'on', false);
do $$ begin
  perform public.get_test_answer_key('40000000-0000-0000-0000-000000000001');
  raise exception 'FAILED: no-access student got keys';
exception when insufficient_privilege then raise notice 'ok: no MCQ access refused'; end $$;
select set_config('test.no_mcq', '', false);

-- ------------------------------------------------------------------ cap
reset role;
update private.grading_settings set daily_reveal_cap = 3;
select t.check((select count(*) = 3 from private.answer_key_reveals where user_id = '00000000-0000-0000-0000-000000000001'),
  'reveals logged once per question');
-- Student 2 at the cap from older reveals: 1 counts within 24h after aging others.
insert into public.test_block_items values ('40000000-0000-0000-0000-000000000003', 2, '30000000-0000-0000-0000-000000000002');
insert into public.test_block_items values ('40000000-0000-0000-0000-000000000003', 3, '30000000-0000-0000-0000-000000000003');
insert into private.answer_key_reveals (user_id, question_id, answered, first_revealed_at) values
  ('00000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000004', true, now()),
  ('00000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000005', true, now() - interval '1 hour');
update public.test_blocks set status = 'completed' where id = '40000000-0000-0000-0000-000000000003';
insert into public.test_responses (block_id, question_id, selected_choice_labels, submitted)
values ('40000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000003', array['A'], true);
set role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-000000000002', false);
select t.check(
  (select count(*) filter (where not capped) = 1
      and count(*) filter (where capped) = 2
      and bool_and(not capped) filter (where question_id = '30000000-0000-0000-0000-000000000003')
   from public.get_test_answer_key('40000000-0000-0000-0000-000000000003')),
  'cap: one slot left goes to the answered question, the rest come back capped');
select t.check(
  (select count(*) filter (where not capped) = 1 from public.get_test_answer_key('40000000-0000-0000-0000-000000000003')),
  'cap: already revealed question stays revealed without counting again');
reset role;
update private.answer_key_reveals set first_revealed_at = now() - interval '25 hours' where user_id = '00000000-0000-0000-0000-000000000002';
set role authenticated;
select t.check(
  (select count(*) filter (where not capped) = 3 from public.get_test_answer_key('40000000-0000-0000-0000-000000000003')),
  'cap: rolls over after 24 hours');
reset role;
update private.grading_settings set daily_reveal_cap = 2500;

-- ---------------------------------------------------------------- switch on
update private.grading_settings set hide_answer_keys = true;
set role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-000000000001', false);
select t.check((select count(*) = 0 from public.question_choices), 'switch on: student reads no question_choices rows');
select t.check((select count(*) = 0 from public.questions), 'switch on: student reads no questions rows');
select t.check(
  (select count(*) > 0 and bool_and(c->'is_correct' = 'null'::jsonb) and bool_and(r.explanation = '') and bool_and(r.explanation_image_url is null)
   from private.get_accessible_question_catalog_page(100, 0) r, jsonb_array_elements(r.choices) c),
  'switch on: catalog page hides is_correct and explanation');
select t.check(
  (select count(*) > 0 and bool_and(c->'is_correct' = 'null'::jsonb) and bool_and(r.explanation = '')
   from public.get_question_catalog_page_after(null, 100) r, jsonb_array_elements(r.choices) c),
  'switch on: keyset catalog hides is_correct and explanation');
select t.check(
  (select count(*) > 0 and bool_and(is_correct is null) from private.get_accessible_question_choices(array['30000000-0000-0000-0000-000000000001'::uuid])),
  'switch on: choice RPC hides is_correct');
select t.check(
  (select count(*) > 0 and bool_and(explanation = '') from private.get_accessible_questions_page(100, 0)),
  'switch on: questions page hides explanation');
select t.check(
  (select r->>'is_correct' = 'false' from public.submit_test_answer('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', array['B']) r),
  'switch on: grading RPC still works');

select set_config('test.uid', '00000000-0000-0000-0000-00000000000a', false);
select t.check((select count(*) = 20 from public.question_choices), 'switch on: admin reads every choice');
select t.check(
  (select bool_or((c->>'is_correct')::boolean) and bool_or(r.explanation <> '')
   from private.get_accessible_question_catalog_page(100, 0) r, jsonb_array_elements(r.choices) c),
  'switch on: admin catalog keeps keys');
select t.check(
  (select count(*) = 3 from public.get_test_answer_key('40000000-0000-0000-0000-000000000003')),
  'admin reads a student block key without cap');
reset role;
select t.check(
  (select count(*) = 0 from private.answer_key_reveals where user_id = '00000000-0000-0000-0000-00000000000a'),
  'admin reveals are not logged');

-- Private tables are not readable by clients.
set role authenticated;
do $$ begin
  perform 1 from private.grading_settings;
  raise exception 'FAILED: grading_settings readable';
exception when insufficient_privilege then raise notice 'ok: grading_settings not readable'; end $$;
do $$ begin
  perform private.claim_answer_key_reveals(null, array[gen_random_uuid()], null);
  raise exception 'FAILED: claim_answer_key_reveals callable';
exception when insufficient_privilege then raise notice 'ok: claim_answer_key_reveals not callable'; end $$;
reset role;

\echo 'ALL SERVER GRADING CHECKS PASSED'
