# Backup and restore runbook

MedBank has one hosted Supabase project (`fzjzjzdamehxbgikiskt`) and no
staging copy, so the hosted backups are the only way back from a bad
migration, a bulk delete or corrupted data.

## What protects the data today

| Layer | What it covers | Where |
|-------|----------------|-------|
| Supabase daily backups | Whole database, kept 7 days on Pro | Dashboard → Database → Backups |
| Point-in-time recovery (PITR) | Restore to any second in the window | Paid add-on — **check whether it is on**; turn it on before a big release or term start |
| `private.question_change_log` | Which questions changed, for the app's delta sync | Not a backup: ids and versions only |
| `archive.deleted_accounts` | Copy of a deleted account's profile and related rows | Purged after 90 days (`purge-deleted-accounts-archive` cron) |
| Admin JSON backup | Courses/topics/questions export from the admin panel | Content only; no users, results or enrollments |
| Storage buckets | Question images, course videos, materials | **Not** in database backups; Supabase Storage has no versioning |

## Before anything risky

1. Note the time (UTC). With PITR this is your restore point.
2. Without PITR, export what you are about to change, e.g. in the SQL editor:
   `copy (select * from public.questions where course_id = '...') to stdout with csv header`
   or use the admin JSON backup for content.
3. Apply migrations one at a time with `apply_migration` (or the SQL editor),
   never `supabase db push` (it would also push migrations that are kept
   unapplied on purpose).
4. Keep the rollback file (`supabase/rollbacks/<version>.down.sql`) open.

## Recovering

- **A migration did the wrong thing, data intact:** run its rollback file.
- **Rows deleted or overwritten in one table:** restore a daily backup or a
  PITR point into a **new project** (Dashboard → Backups → Restore to new
  project), copy the affected rows back with `pg_dump --table` / `copy`, then
  delete the temporary project. Restoring over production rolls back every
  student's answers since that point; only do it when the damage is wider
  than what you would lose.
- **Storage files deleted:** not recoverable from Supabase. Keep originals of
  course videos and materials outside Supabase.

## Once a term

Restore the latest daily backup into a temporary project, check that
`select count(*) from public.questions`, `profiles` and
`test_history_entries` look right, then delete the project. A backup that has
never been restored is not known to work.
