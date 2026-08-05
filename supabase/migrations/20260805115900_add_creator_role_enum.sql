-- Adds the `creator` role: a course author who sits between student and admin.
--
-- Deliberately alone in its own migration. `alter type ... add value` cannot
-- share a transaction with any statement that uses the new label, so the rest
-- of the creator workflow ships in the migration that follows this one.
alter type public.app_user_role add value if not exists 'creator';
