-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- Take the pop-up RPCs back off the anonymous API.
--
-- `grant execute ... to authenticated` does not remove the EXECUTE that
-- Postgres grants to PUBLIC when a function is created, so both functions
-- shipped callable by the `anon` role through /rest/v1/rpc — which for a
-- SECURITY DEFINER function is exactly what the database linter flags
-- (0028_anon_security_definer_function_executable).
--
-- Neither one leaks anything today: with no JWT, `auth.uid()` is null, so
-- get_my_active_popups finds no profile and returns nothing, and
-- record_popup_event fails the NOT NULL on user_id. That is an accident of
-- how they are written rather than a decision, and it is one edit away from
-- not being true. Every other definer function in this database
-- (get_my_platform_course_access, redeem_platform_course_coupon) is granted
-- to `authenticated` alone; these two now match.

revoke execute on function public.get_my_active_popups() from public, anon;

revoke execute on function public.record_popup_event(uuid, text)
  from public, anon;

grant execute on function public.get_my_active_popups() to authenticated;

grant execute on function public.record_popup_event(uuid, text)
  to authenticated;
