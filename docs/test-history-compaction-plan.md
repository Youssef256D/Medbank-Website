# Plan: shrink `test_history_entries` (proposal, not approved)

Status: **waiting for owner approval** (2026-10-27). Nothing below has run.

## Where the space goes (measured 2026-10-27)

- 5,326 entries, 322 MB of a 1,013 MB database.
- Each entry's `payload.questionSnapshots` averages ~93 kB (a full copy of
  every question in the test); `responses` ~14 kB; everything else is small.
- Inside a question snapshot, the largest fields are `choices` (~260 B, choice
  text), `stem` (~95 B), `explanation` (~75 B) and `explanationImage`. The
  rest (ids, course/topic names, `correct`, status) is a few hundred bytes.

## What reads the snapshots

| Reader | Needs |
|--------|-------|
| App `history_score.dart` (score) | `correct` labels, one snapshot per question (total = snapshot count) |
| App `topic_stats.dart`, `subject_progress.dart`, `question_pools.dart` | course / topic / system names, ids |
| App `history_screen.dart`, `test_tiles.dart` | the above; review shows question text |
| Website `getQuestionForSession` | snapshot first, **falls back to the live question** by id |
| Admin student results (`admin_student_results` RPCs) | `responses`, snapshot `dbId`, `course`/`topic`, `correct` (checked) |

## Proposal

Keep a **slim snapshot** per question in old entries: `id`, `dbId`,
`correct`, `course`, `system`, `topic`, `qbankCourse`, `qbankTopic`,
`status`, `difficulty`, and choice **labels** (no text). Drop `stem`,
choice text, `explanation`, `explanationImage` (and `questionImage`).

- Scores, topic stats, pools and admin results are unchanged: they only use
  the kept fields.
- Review of a slimmed test shows the **current** question text from the live
  bank (the website already does this; the app needs the same fallback).
  If a question was later edited, review shows the edited version; if it was
  deleted, review shows "question no longer available" for that one item.

Estimated saving: roughly half the table (~150 MB), plus faster history loads
on phones. This is an estimate from a 3% sample; measure on a copy first.

## Steps

1. **App:** when a snapshot has no `stem`, load the question by `dbId` from the
   local catalog (or fetch it), and show "no longer available" if it is gone.
   Ship and wait until most users are on that version.
2. **Website:** confirm `getQuestionForSession` fallback covers review, the
   results table and the PDF/print views; add the "no longer available" state.
3. **Rule:** slim only entries completed more than 30 days ago; new tests keep
   full snapshots, so a fresh review is always exact.
4. **Migration:** a `private.slim_history_snapshots(batch int)` function that
   rewrites `payload` in batches of ~200 rows (to avoid long locks and WAL
   spikes), plus a nightly cron that slims entries as they pass 30 days.
   Before running: export the affected rows (backup runbook), note the time
   for PITR.
5. Run `VACUUM (ANALYZE) public.test_history_entries` afterwards; disk use
   shrinks only after Supabase reclaims space (or `VACUUM FULL` in a quiet
   window, which locks the table).

## Rollback

Slimming deletes text that only the live bank still has, so it cannot be
undone from the database alone. Keep the exported rows (step 4) for 90 days.

## Decision needed

- Approve slimming at all?
- Age threshold (30 days proposed)?
- Is "review shows the current version of an edited question" acceptable?
