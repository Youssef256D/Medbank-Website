-- 2026-07-21 — MCQ vs Video Courses naming split.
--
-- Context: the product has two unrelated "course" concepts that were both
-- surfaced to users (and to the Flutter agent) as "Courses":
--
--   * public.courses / public.course_topics  -> MCQ SUBJECTS (question bank)
--   * public.platform_courses / platform_*   -> VIDEO COURSES (the LMS)
--
-- The UI has been renamed to "MCQ Subjects" and "Video Courses". Renaming the
-- underlying tables was deliberately REJECTED: `courses` carries 34 RLS
-- policies, 12 FK constraints and 12 SQL functions, and rewriting those is an
-- access-control risk on live student data for zero clarity gain.
--
-- Instead this migration is purely ADDITIVE: read-only alias views that give
-- the new vocabulary a real, self-documenting name to code against.
--
-- SECURITY: both views are created WITH (security_invoker = true) so that the
-- RLS policies on the underlying tables are evaluated as the QUERYING user.
-- Without this flag a view runs as its owner and would silently bypass RLS.
-- Do not remove that setting.
--
-- Rollback: supabase/rollbacks/20260721120000_add_mcq_subject_alias_views.sql

create or replace view public.mcq_subjects
  with (security_invoker = true)
  as select * from public.courses;

create or replace view public.mcq_subject_topics
  with (security_invoker = true)
  as select * from public.course_topics;

comment on view public.mcq_subjects is
  'Alias of public.courses. These are MCQ SUBJECTS (question bank), NOT the video LMS. The video learning platform lives in public.platform_courses. Read-only; security_invoker so table RLS applies.';

comment on view public.mcq_subject_topics is
  'Alias of public.course_topics. Topics belonging to an MCQ subject. Read-only; security_invoker so table RLS applies.';

-- Also label the real tables so anyone (human or agent) inspecting the schema
-- sees which concept they are looking at.
comment on table public.courses is
  'MCQ SUBJECTS — the question-bank curriculum. NOT the video learning platform (see public.platform_courses). Exposed as the alias view public.mcq_subjects.';

comment on table public.course_topics is
  'Topics within an MCQ SUBJECT (public.courses). NOT video-course content.';

comment on table public.platform_courses is
  'VIDEO COURSES — the video learning platform (LMS). NOT the MCQ question bank (see public.courses / public.mcq_subjects).';

-- Views inherit no grants; mirror the underlying table read access.
grant select on public.mcq_subjects to authenticated;
grant select on public.mcq_subject_topics to authenticated;
