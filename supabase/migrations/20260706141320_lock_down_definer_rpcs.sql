revoke execute on function public.bootstrap_student_enrollments_from_auth_metadata(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.delete_old_test_history_entries(integer) from public, anon, authenticated;
revoke execute on function public.get_admin_question_count_summary() from public, anon;

alter function private.course_code_key(text) set search_path = '';
alter function private.course_name_key(text) set search_path = '';;
