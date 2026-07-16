-- BUG 3: questions.question_image_url / explanation_image_url hold pasted CSV
-- row text from a bad import, not URLs. NULL out anything that is not a valid
-- http(s) URL, then constrain the columns so only NULL or http(s) can be stored.
-- Snapshot (verified before running): question_image_url 4/4 invalid,
-- explanation_image_url 234/234 invalid; all get nulled.

update public.questions
set question_image_url = null
where question_image_url is not null
  and question_image_url !~ '^https?://';

update public.questions
set explanation_image_url = null
where explanation_image_url is not null
  and explanation_image_url !~ '^https?://';

alter table public.questions
  add constraint questions_question_image_url_http_ck
  check (question_image_url is null or question_image_url ~ '^https?://')
  not valid;

alter table public.questions
  add constraint questions_explanation_image_url_http_ck
  check (explanation_image_url is null or explanation_image_url ~ '^https?://')
  not valid;

-- Validate now that the data is clean (rows were fixed above).
alter table public.questions validate constraint questions_question_image_url_http_ck;
alter table public.questions validate constraint questions_explanation_image_url_http_ck;
