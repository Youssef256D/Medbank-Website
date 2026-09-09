-- Archive store for permanently removed accounts.
--
-- Deleting a row from auth.users cascades through profiles and eight child
-- tables, which releases the email address for re-registration but destroys the
-- account's history. This table holds a JSONB snapshot taken immediately before
-- that delete, so the removal stays auditable.
--
-- It is a record, not an undo button: restoring an account would mean creating a
-- new auth.users row with a new id and remapping every user_id in the snapshot.
--
-- The archive schema is deliberately NOT added to the PostgREST exposed schemas,
-- so the anon/authenticated roles cannot reach it over the API. RLS with no
-- policies is defence in depth on top of that.

create schema if not exists archive;

revoke all on schema archive from anon, authenticated;

create table if not exists archive.deleted_accounts (
  id              uuid primary key,
  email           text,
  full_name       text,
  role            text,
  public_user_id  bigint,
  auth_providers  text[]      not null default '{}',
  deleted_at      timestamptz not null default now(),
  deleted_by      text,
  reason          text,
  auth_user       jsonb       not null,
  profile         jsonb,
  related         jsonb       not null default '{}'::jsonb
);

comment on table archive.deleted_accounts is
  'Snapshots of accounts removed from auth.users, captured immediately before deletion. Audit record only - not restorable in place.';
comment on column archive.deleted_accounts.related is
  'Per-table JSONB arrays of the rows that cascaded away with the account (enrollments, test history, test blocks, and so on).';

create index if not exists deleted_accounts_email_idx
  on archive.deleted_accounts (lower(email));
create index if not exists deleted_accounts_deleted_at_idx
  on archive.deleted_accounts (deleted_at desc);
create index if not exists deleted_accounts_public_user_id_idx
  on archive.deleted_accounts (public_user_id);

alter table archive.deleted_accounts enable row level security;

revoke all on archive.deleted_accounts from anon, authenticated;
