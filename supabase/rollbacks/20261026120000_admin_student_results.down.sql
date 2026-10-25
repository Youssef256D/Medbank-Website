-- Rollback for 20261026120000_admin_student_results.sql and
-- 20261026120100_backfill_test_history_answers.sql: removes the admin
-- Student results functions, the trigger and the copied answers table.
-- test_history_entries itself is untouched.

drop function if exists public.admin_results_overview(timestamptz, timestamptz, smallint, smallint, uuid, text);
drop function if exists public.admin_results_subjects(timestamptz, timestamptz, smallint, smallint, uuid);
drop function if exists public.admin_results_topics(uuid, timestamptz, timestamptz, smallint, smallint, uuid);
drop function if exists public.admin_results_missed_questions(uuid, uuid, integer, timestamptz, timestamptz, smallint, smallint, uuid, integer, integer);
drop function if exists public.admin_results_students(text, text, timestamptz, timestamptz, smallint, smallint, uuid, integer, integer);
drop function if exists public.admin_results_student(uuid, timestamptz, timestamptz);

drop trigger if exists trg_test_history_answers_insert on public.test_history_entries;
drop trigger if exists trg_test_history_answers_update on public.test_history_entries;
drop function if exists private.test_history_answers_sync();
drop function if exists private.refresh_test_history_answers(uuid);
drop function if exists private.results_label_set(jsonb);
drop function if exists private.results_try_uuid(text);

drop table if exists public.test_history_answers;

delete from supabase_migrations.schema_migrations
where version in ('20261026120000', '20261026120100');

-- 20261026140000_results_last_tests and 20261026130000_results_time_zero_is_unknown
-- (the latter only changed rows of the table dropped above).
drop function if exists public.admin_results_last_tests(uuid[]);
delete from supabase_migrations.schema_migrations
where version in ('20261026130000', '20261026140000');
