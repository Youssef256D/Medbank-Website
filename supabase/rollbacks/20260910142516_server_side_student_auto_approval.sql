-- Reverses 20260910160000_server_side_student_auto_approval.sql.
--
-- After this, approval reverts to the client-side sweep only, which runs solely
-- while an admin has the dashboard open. Students will again sit unapproved
-- whenever no admin is watching.
--
-- The `auto_approval_blocked_at` column is dropped last. Nothing outside this
-- feature reads it; if you keep the column, an admin suspension recorded while
-- the feature was live simply becomes inert data.

begin;

select cron.unschedule('student-auto-approval');

drop trigger if exists trg_profiles_auto_approval on public.profiles;

drop function if exists private.run_student_auto_approval_sweep();
drop function if exists private.profiles_auto_approval();
drop function if exists private.student_profile_is_complete(text, text, smallint, smallint, uuid);
drop function if exists private.student_phone_is_valid(text);

alter table public.profiles drop column if exists auto_approval_blocked_at;

commit;
