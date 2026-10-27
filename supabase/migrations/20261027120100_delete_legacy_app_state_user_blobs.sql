-- Delete the legacy user-list blobs from app_state.
--
-- `mcq_users` (10 records, last written 2026-02-17) and `g:mcq_users`
-- (3 records, 2026-03-10) are pre-relational copies of the user list: names,
-- emails, phones, and in `mcq_users` two plain-text `password` values. Users
-- live in `profiles` + Supabase Auth now. Nothing writes these keys any more
-- (`users` is a relational sync key, so `scheduleSupabaseWrite` skips it);
-- the only reader is the admin fallback `hydrateUsersFromSupabaseBackup`,
-- which then simply finds nothing.
--
-- Not reversible on purpose (no rollback file): the point is that the
-- passwords stop existing. Apply after 20261027120000_lock_down_app_state.

delete from public.app_state
where storage_key in ('mcq_users', 'g:mcq_users');
