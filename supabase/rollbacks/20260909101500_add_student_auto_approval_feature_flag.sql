-- Reverses 20260909101500_add_student_auto_approval_feature_flag.sql.
-- Removing the row turns auto-approval off (a missing flag reads as false).

begin;

delete from public.app_feature_flags
where feature_key = 'student_auto_approval';

commit;
