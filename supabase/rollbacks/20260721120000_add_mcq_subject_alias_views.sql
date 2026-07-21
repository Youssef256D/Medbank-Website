-- Rollback for 20260721120000_add_mcq_subject_alias_views.sql
-- Purely additive migration, so the reverse is a clean drop. The underlying
-- tables, policies and constraints were never touched.

drop view if exists public.mcq_subject_topics;
drop view if exists public.mcq_subjects;

comment on table public.courses is null;
comment on table public.course_topics is null;
comment on table public.platform_courses is null;
