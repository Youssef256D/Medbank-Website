-- Rollback for 20260909224007_add_account_archive.sql
--
-- WARNING: this destroys the only record of the accounts that were deleted.
-- Export archive.deleted_accounts before running it.

drop table if exists archive.deleted_accounts;
drop schema if exists archive;
