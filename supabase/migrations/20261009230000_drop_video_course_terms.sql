-- Video courses no longer carry an academic year or semester.
--
-- Organizations decide who sees a video course
-- (20261009210000_organizations, 20261009210100_video_course_audience), and
-- the year was only ever a label on one. The MCQ Bank keeps its year and
-- semester: `public.courses`, `profiles.academic_year/academic_semester` and
-- the term enrollment are untouched.
--
-- App builds up to 1.0.1+44 select these columns, so their video course list
-- fails until the student updates. That cost was accepted; the MCQ Bank keeps
-- working on those builds.
--
-- Dropping the columns also drops `platform_courses_name_term_uniq`,
-- `idx_platform_courses_term`, `idx_platform_course_suggestions_target_term`
-- and the range checks on them.

drop function if exists private.platform_suggestion_matches_current_profile(integer, integer);

alter table public.platform_course_suggestions
  drop column if exists target_academic_year,
  drop column if exists target_semester;

alter table public.platform_courses
  drop column if exists academic_year,
  drop column if exists academic_semester;

comment on table public.platform_course_suggestions is
  'Video courses admins recommend on the student Home, optionally to one organization.';
