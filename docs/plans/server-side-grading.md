# Plan: server-side grading (hide answer keys until a question is answered)

Status: **approved 2026-10-27** (RLS change, answers-final rule, 2,500/day cap); phase 1 built on branches. Nothing applied, nothing pushed.

## The problem today

Any approved, enrolled student can read every answer key without answering:

- `question_choices.is_correct` is readable through the table (`choices_select`
  lets students select their accessible rows) and through
  `get_accessible_question_choices`.
- `questions.explanation` / `explanation_image_url` are readable through the
  table (`questions_select`) and every catalog RPC:
  `get_question_catalog_page_after`, `get_question_catalog_changes`,
  `get_accessible_question_catalog_page`, `get_accessible_questions_page`
  (all go through `private.accessible_catalog_rows` or similar).

Both clients download the full key with the bank and grade on the device.

## What changes, in one sentence

Students get the bank **without** `is_correct`, `explanation` and
`explanation_image_url`; the key for a question comes from the server only
after the student has **submitted an answer** to it in one of their tests, or
the test is **finished** (so review can show skipped questions). Admins are
unchanged.

The model is the same one the course quizzes already use
(`get_platform_quiz` / `submit_platform_quiz`, students have no SELECT on
`platform_course_quiz_options`).

## Honest limit

This stops "download the bank with answers in one call". It cannot stop a
student who creates a 1,000-question test, finishes it blank and reads the
review: that is the product working as designed. To make that path slow and
visible:

- every key handed out is logged (`private.answer_key_reveals`: user,
  question, block, answered or skipped, time);
- a rolling 24-hour cap per student on distinct questions revealed
  (proposed **2,500**; the heaviest real day on record is 1,820 answered
  questions, the 99th percentile is 519). Over the cap, review shows
  "answer hidden, try again tomorrow" for the extra questions;
- answered questions are final on the server (see 3 below), so blank or
  guessed answers stay in that student's results and in admin Student results.

## Database (one migration + rollback)

`supabase/migrations/20261027120000_server_side_grading.sql`,
`supabase/rollbacks/20261027120000_server_side_grading.down.sql`.

1. **Switch** `private.answer_keys_hidden()` reading one row in a new
   `private.grading_settings` table (`hide_answer_keys boolean`, default
   **false**, `daily_reveal_cap int` default 2500). Everything below that
   hides data checks this switch, so phase 2 is a one-row update and
   flipping it back is the emergency undo.
2. **New RPCs** (SECURITY DEFINER, `search_path = ''`, students only touch
   their own blocks, same access checks as today plus module locks):
   - `submit_test_answer(p_block_id, p_question_id, p_selected_labels text[],
     p_flagged bool default null, p_notes text default null) returns jsonb` —
     checks the block is the caller's and not finished, the question is one of
     its `test_block_items`, labels are A–E and exist; upserts the
     `test_responses` row as submitted; returns
     `{question_id, selected_labels, submitted, correct_labels, is_correct,
     explanation, explanation_image_url}`. If the row was already submitted
     with another answer, the stored answer wins and is what comes back.
     One round trip for tutor mode.
   - `get_test_answer_key(p_block_id, p_question_ids uuid[] default null)
     returns table(question_id, correct_labels, explanation,
     explanation_image_url)` — only for questions of that block that have a
     submitted response, or all of them when the block is `completed`. Used for
     timed-mode results, review, resuming a test, and the website/app picking up
     answers the other client gave in a shared test.
   - Both log to `private.answer_key_reveals` and apply the daily cap
     (a question already revealed to that student never counts twice).
   - Admins: both work and skip the cap/log.
3. **Answers are final.** Extend `private.protect_test_response_answer()`:
   once a row is `submitted` with a selection, an update keeps the old
   selection and `submitted` (flag and notes still update). Today both clients
   already refuse to change a submitted answer; this makes it hold for any
   client. (The 2026-10-26 log mentions "un-submitting a question in the
   app"; the current app code has no such action, so nothing is lost.)
4. **Catalog stops returning the key** when the switch is on and the caller is
   not an admin: `private.accessible_catalog_rows`,
   `private.get_accessible_question_catalog_page`,
   `private.get_accessible_questions_page`,
   `private.get_accessible_question_choices` return `is_correct = null`,
   `explanation = ''`, `explanation_image_url = null`. Same columns and types,
   so no client breaks on the shape.
5. **RLS (needs your explicit OK):** `questions_select` and `choices_select`
   become admin-only **when the switch is on**
   (`is_admin OR (not private.answer_keys_hidden() AND <today's rule>)`).
   Students already read questions only through the RPCs above; the
   direct-table reads in `main.js` are old fallbacks for when those RPCs
   are missing. Admin, insert/update/delete and area-guard policies are not
   touched.
6. The `test_history_answers` trigger keeps working (it is SECURITY DEFINER
   and falls back to `question_choices`).

Rollback file: drops the two RPCs, the reveals log and the settings table,
restores the five functions, the trigger function and the two policies to
their current definitions.

## Rollout (the important part)

There is no minimum-app-version check, and older app builds grade from
`is_correct` in the catalog. If keys were hidden on day one, every answer in an
old app would show as wrong. So:

- **Phase 1** — apply the migration with the switch **off**. Nothing changes
  for anyone. Ship the website and an app update that always grade through
  `submit_test_answer` / `get_test_answer_key` and never trust a key from the
  catalog (they still work if the catalog has one, which it does).
- **Phase 2** — your call, after most students have updated the app (a popup
  through `app_popups` can ask them to): set `hide_answer_keys = true`.
  Old app builds then show answers as unknown, not as wrong (see app notes).
  Undo = set it back to false.

## Website (`main.js`)

- **Grading helper:** a `sessionAnswerKeys` map on each session (kept in
  `questionSnapshots[qid].correct` / `.explanation` /
  `.explanationImage`, which review and history already read). The bank
  question no longer supplies the key for students; `getQuestionForSession`
  already prefers the snapshot, so `isSubmittedResponseCorrect`,
  `renderInlineExplanationPane`, review, analytics and the incorrect queue
  keep working once the snapshot has the key.
- **"Not graded yet" state:** a submitted response whose snapshot has no key
  yet shows "Checking…" (online) or "Saved — the answer shows when you are
  back online" (offline) instead of right/wrong. Score and analytics skip such
  questions until graded; the session is never stored as finished with
  ungraded questions without a later `get_test_answer_key` pass.
- **Tutor mode:** the Submit button calls `submit_test_answer`; the session's
  block must exist first, so the first submit awaits the block from
  `syncLiveTestBlocks` (it is created on test start today). On failure the
  answer is kept locally as submitted + ungraded and retried by the existing
  live-block sync, which then calls `get_test_answer_key`.
- **Timed mode:** answers keep syncing as now; on finish, after the block is
  marked `completed`, one `get_test_answer_key(block)` call fills every
  snapshot, then results render. Offline finish shows results once back online.
- **Shared tests:** `applyLiveTestBlockResponses` already merges remote
  submitted answers; for those without a key in the snapshot it collects ids
  and calls `get_test_answer_key` once per pull.
- **Saved history** keeps `questionSnapshots` with the revealed keys, so old
  and new review keep working offline.
- **Cache clean-up:** for students, drop `correct` / `explanation` from the
  cached bank on load once the server reports keys hidden (bump the catalog
  refresh version), so nothing in the browser grades from stale keys.
- Admin pages (question editor, reports, results, counts) are unchanged.
- Search: students no longer match on explanation text (it is not in the bank).

## Flutter app (`Medbank-App`, own worktree from `origin/main`)

- `CatalogChoice.isCorrect` becomes `bool?` (null = unknown);
  `CatalogQuestion.explanation` may be empty. New `AnswerKey`
  (`correctLabels`, `explanation`, `explanationImageUrl`) per question,
  held in `TestRunnerState.answerKeys`.
- `TestsRepository.submitAnswer(...)` → `submit_test_answer`;
  `fetchAnswerKey(blockId, ids)` → `get_test_answer_key`.
- `TestRunnerController.submitCurrentQuestion()` (tutor): optimistic lock,
  call the RPC, store the key; offline → "graded when you're back online",
  retried by the existing write queue. `submitTest()` (timed): after
  completion, fetch the whole block key, then score.
  `TestScore.compute` takes keys from `answerKeys`; questions without a key
  count as ungraded, not wrong.
- Resume / history: on open, `fetchAnswerKey(blockId)` for the submitted
  questions; `history_payload.dart` keeps writing `questionSnapshots` with
  the keys the app was given.
- Old builds after phase 2: `correctLabel` is null → current code would show
  wrong. Unfixable for already-installed builds, hence the phased rollout.
- Admin screens keep their direct table reads (admins are unaffected).

## Tests

- Website: new `tests/server-grading.test.js` (fake RPCs: tutor submit,
  offline submit then retry, timed finish fills keys, shared-test pull fetches
  missing keys, ungraded questions not counted as wrong); existing
  live-block tests updated.
- App: unit tests for `TestScore` with ungraded questions, controller tests
  with a fake repository for tutor/timed/offline.
- SQL: a `supabase/tests/server_grading.sql` script run against a Supabase
  branch (not production) checking: student cannot read `is_correct` /
  explanation via table or catalog with the switch on; key only after submit
  or completion; another student's block refused; cap and log; submitted
  answer cannot be changed; admin unaffected.

## Not in scope (follow-ups)

- `objective` stays visible (not an answer).
- Course-quiz grading is already server-side.
- An admin view of `answer_key_reveals` (who hit the cap).

## What I need from you

1. Approve the plan, including the **RLS change in step 5** and the
   **"answers are final on the server" rule in step 3**.
2. The daily cap: 2,500 distinct questions per student per 24 h, or another
   number.
