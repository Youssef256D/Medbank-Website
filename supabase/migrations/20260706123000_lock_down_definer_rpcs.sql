-- Security-advisor cleanup:
-- 1. SECURITY DEFINER RPCs that are internal-only (called by DB triggers or
--    pg_cron, never by clients) lose EXECUTE for anon/authenticated.
-- 2. get_admin_question_count_summary stays callable by authenticated (the
--    admin dashboard calls it and it self-checks the admin role) but loses
--    anon access.
-- 3. private.course_code_key / course_name_key (pure text normalizers used by
--    course key indexes) get a pinned search_path.

revoke execute on function public.bootstrap_student_enrollments_from_auth_metadata(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.delete_old_test_history_entries(integer) from public, anon, authenticated;
revoke execute on function public.get_admin_question_count_summary() from public, anon;

alter function private.course_code_key(text) set search_path = '';
alter function private.course_name_key(text) set search_path = '';
