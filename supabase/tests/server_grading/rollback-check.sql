-- After the rollback: students read keys again and the new objects are gone.
\set ON_ERROR_STOP on
set role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-000000000001', false);
select t.check((select count(*) = 3 from public.question_choices where is_correct), 'rollback: student reads is_correct again');
select t.check(
  (select bool_or((c->>'is_correct')::boolean) from private.get_accessible_question_catalog_page(100, 0) r, jsonb_array_elements(r.choices) c),
  'rollback: catalog returns is_correct again');
reset role;
select t.check(to_regprocedure('public.submit_test_answer(uuid,uuid,text[],boolean,text)') is null, 'rollback: submit_test_answer dropped');
select t.check(to_regclass('private.answer_key_reveals') is null, 'rollback: reveal log dropped');
\echo 'ROLLBACK CHECKS PASSED'
