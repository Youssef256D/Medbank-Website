-- BUG 4: get_admin_question_count_summary() is SECURITY DEFINER.
-- DECISION (owner-confirmed): keep EXECUTE for `authenticated`. The admin
-- dashboard calls this RPC directly from the browser as the `authenticated`
-- role (main.js: client.rpc("get_admin_question_count_summary")), and the
-- function already self-gates: it looks up profiles.role for auth.uid() and
-- raises 42501 unless the caller is an admin. Revoking `authenticated` would
-- break the admin dashboard in production without adding real protection.
--
-- Defense-in-depth: make sure PUBLIC and anon cannot execute it. (The daily
-- students/anon path must never reach it.) search_path is already pinned to ''.
--
-- The advisor lint `authenticated_security_definer_function_executable` for
-- this function is therefore an accepted, by-design finding.
revoke execute on function public.get_admin_question_count_summary() from public;
revoke execute on function public.get_admin_question_count_summary() from anon;
