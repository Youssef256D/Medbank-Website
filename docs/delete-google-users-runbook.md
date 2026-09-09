# Runbook — Delete Google-registered accounts

> **EXECUTED 2026-09-10.** 779 accounts were archived and deleted: 777 students
> (661 google-only + 116 who also had a password) and 2 admins. Kept:
> `code.youssefaayoub@gmail.com` (yours) and `testadmin@medbank.com`. See
> **What was actually run** at the bottom. The steps below are kept as the
> procedure for next time.

Purpose: permanently remove accounts that registered through Google sign-in, so
their email addresses are released and those people can register again with
email + password.

**This is irreversible.** Run Step 1 and Step 2 before Step 3. Step 2 is the
only thing that makes any part of this recoverable.

Where to run it: the Supabase **SQL Editor** in the dashboard
(Project → SQL Editor). `supabase db push` cannot do this — deleting Auth users
is not a schema migration — and the repo currently has no working local DB path
(no `psql`, Docker not running).

---

## Why the delete targets `auth.users`

`public.profiles.id` is `REFERENCES auth.users(id) ON DELETE CASCADE`, and eight
tables cascade from `profiles`. So a single delete on `auth.users` removes the
whole graph.

Deleting only the `profiles` row would **not** release the email — the
`auth.users` row still holds it, and signup would keep failing with "already
registered". Delete from `auth.users`, nothing else.

## How a "Google user" is identified here

Use `auth.identities`, not `profiles.auth_provider`.

`profiles.auth_provider` was populated by a one-time backfill
(`20260218054626_add_profiles_auth_provider.sql`) and is maintained on a
best-effort basis by the signup path, so it can be stale or null.
`auth.identities` is the ground truth for which providers an account can
actually sign in with.

This matters for one group in particular: an account can hold **both** a Google
identity and an email/password identity. Those people are **not locked out** —
they can already sign in with their password today. Step 1 counts them
separately so you can decide. The Step 3 delete excludes them by default; remove
the marked line to include them.

---

## Step 1 — Audit (read-only, run this first)

```sql
-- What is actually out there. Nothing is modified.
with identities as (
  select
    u.id,
    u.email,
    bool_or(i.provider = 'google') as has_google,
    bool_or(i.provider = 'email')  as has_password
  from auth.users u
  join auth.identities i on i.user_id = u.id
  group by u.id, u.email
)
select
  p.role,
  case
    when idn.has_google and idn.has_password then 'google + password (NOT locked out)'
    when idn.has_google then 'google only (locked out of the website)'
  end as account_type,
  count(*) as accounts
from identities idn
join public.profiles p on p.id = idn.id
where idn.has_google
group by 1, 2
order by 1, 2;
```

Then look at exactly what would be destroyed:

```sql
with google_only as (
  select u.id
  from auth.users u
  join auth.identities i on i.user_id = u.id
  group by u.id
  having bool_or(i.provider = 'google') and not bool_or(i.provider = 'email')
)
select
  p.email,
  p.full_name,
  p.role,
  p.public_user_id                              as medbank_id,
  p.approved,
  p.created_at,
  (select count(*) from public.test_history_entries t   where t.user_id = p.id) as previous_tests,
  (select count(*) from public.user_course_enrollments e where e.user_id = p.id) as mcq_enrollments,
  (select count(*) from public.platform_course_enrollments pe where pe.user_id = p.id) as video_courses
from public.profiles p
join google_only g on g.id = p.id
order by p.role, p.created_at;
```

**Stop here if any row has `role = 'admin'`.** Deleting an admin account can
lock you out of your own admin panel. Step 3 guards against this, but confirm
the list looks like what you expect before continuing.

## Step 2 — Export a backup (read-only, do not skip)

Run this and use the SQL Editor's **Download CSV** button. This is your only
record of who was removed and what they had.

```sql
with google_only as (
  select u.id
  from auth.users u
  join auth.identities i on i.user_id = u.id
  group by u.id
  having bool_or(i.provider = 'google') and not bool_or(i.provider = 'email')
)
select jsonb_pretty(jsonb_agg(to_jsonb(x))) as backup
from (
  select
    p.*,
    (select jsonb_agg(to_jsonb(e)) from public.user_course_enrollments e where e.user_id = p.id)   as mcq_enrollments,
    (select jsonb_agg(to_jsonb(t)) from public.test_history_entries t    where t.user_id = p.id)   as test_history,
    (select jsonb_agg(to_jsonb(pe)) from public.platform_course_enrollments pe where pe.user_id = p.id) as video_course_enrollments
  from public.profiles p
  join google_only g on g.id = p.id
) x;
```

Note: this backs up the **data**, not the accounts. Restoring it later would
mean recreating Auth users with new ids and remapping every `user_id`. Treat it
as a record, not an undo button.

## Step 3 — Delete

```sql
begin;

with google_only as (
  select u.id
  from auth.users u
  join auth.identities i on i.user_id = u.id
  group by u.id
  having bool_or(i.provider = 'google')
     and not bool_or(i.provider = 'email')   -- ← remove this line to ALSO delete
                                             --   google+password accounts (people
                                             --   who are not currently locked out)
),
targets as (
  select g.id
  from google_only g
  join public.profiles p on p.id = g.id
  where p.role = 'student'                   -- ← admin/creator guard. Widen only
                                             --   deliberately; deleting an admin
                                             --   can lock you out of the panel.
)
delete from auth.users u
using targets t
where u.id = t.id;

-- Confirm the number matches your Step 1 count, THEN commit.
-- If it does not match, run: rollback;
commit;
```

The `begin` / `commit` wrapper is the point of this step: check the reported row
count against Step 1 before committing, and `rollback` if it disagrees.

## Step 4 — Verify

```sql
-- Expect 0.
select count(*) as remaining_google_only
from auth.users u
join auth.identities i on i.user_id = u.id
group by u.id
having bool_or(i.provider = 'google') and not bool_or(i.provider = 'email');

-- Expect 0 — confirms the emails are released for re-registration.
select count(*) from auth.users where email in ('<one email you deleted>');
```

---

## What those people experience afterwards

- The email is free. They sign up again at the normal signup form.
- Google sign-in is currently hidden on the website
  (`supabase.config.js → googleOAuthEnabled: false`), so they will register with
  email + password. That is the intended outcome here.
- They get a **new MedBank ID** — `public_user_id` is assigned fresh and the old
  number is not reused. Tell them, or admins searching by the old ID will not
  find them.
- They start **unapproved** (`profiles.approved` defaults to false), so they need
  approving again. The new Auto-approve switch on the admin Users page handles
  this automatically once they complete phone, year, semester, and course.
- Their previous tests, progress, and course enrollments are gone and are not
  restored by re-registering.

## One thing to check before you run this

The hosted Google provider is still enabled, and per the 2026-09-06 entry in
`AGENTS.md` the mobile app is unaffected by the website flag — so a student may
be signed in with Google on the **Android app** (released 2026-09-05) right now.
Deleting their account signs them out permanently and wipes their progress.

If that group matters, Step 1's first query separates it out by role and
provider mix, and `public.user_presence` / `public.user_activity_sessions` show
who has been active recently:

```sql
with google_only as (
  select u.id from auth.users u
  join auth.identities i on i.user_id = u.id
  group by u.id
  having bool_or(i.provider = 'google') and not bool_or(i.provider = 'email')
)
select p.email, max(s.created_at) as last_seen
from public.profiles p
join google_only g on g.id = p.id
left join public.user_activity_sessions s on s.user_id = p.id
group by p.email
order by last_seen desc nulls last;
```


---

# What was actually run (2026-09-10)

Run through the Supabase MCP tools against the hosted project, not the SQL
Editor. Scope was confirmed twice: once on which groups to include, and once
specifically on whether to delete the owner's own admin account (answer: no).

### Counts before

| Group | Accounts |
| --- | --- |
| Students, Google only | 661 (584 approved) |
| Students, Google + password | 116 |
| Admins with Google | 3 |
| **Deleted** | **779** (777 students + 2 admins) |
| Kept | `code.youssefaayoub@gmail.com`, plus `testadmin@medbank.com` (no Google) |

Their data: 748 test-history entries, 1,696 test blocks (5,282 items), 2,758 MCQ
enrollments, 511 notifications, 21 push tokens, 1,740 `app_state` rows (18 MB).
23 of them had signed in within 30 days, 14 within 7 — almost certainly through
the Android app, where Google sign-in still works.

### Blockers checked first

`platform_course_coupon_redemptions.user_id` and the three
`platform_course_coupons` provenance columns (`created_by`, `redeemed_by`,
`disabled_by`) are **RESTRICT** against `profiles`. A single coupon redemption
by any target aborts the whole delete. Zero targets held one. Re-run this check
before any future bulk delete:

```sql
with targets as (/* your target set */)
select
  (select count(*) from public.platform_course_coupon_redemptions r join targets t on t.id = r.user_id) as blocking_redemptions,
  (select count(*) from public.platform_course_coupons c join targets t on t.id in (c.created_by, c.redeemed_by, c.disabled_by)) as blocking_coupons;
```

### Step A — archive schema

Migration `supabase/migrations/20260909224007_add_account_archive.sql` creates
`archive.deleted_accounts`. The `archive` schema is **not** in the PostgREST
exposed schemas, and the table has RLS enabled with no policies, so
anon/authenticated cannot read it. Rollback provided — note that running it
destroys the only record of who was deleted.

### Step B — snapshot, then delete

Each account was inserted into `archive.deleted_accounts` with its auth user and
identities, full profile row, and a `related` JSONB object holding enrollments,
test history, test blocks and items, platform enrollments/requests/entitlements,
lesson progress, notifications and reads, push device tokens, presence,
`app_state` keys, and an activity-session summary (count + last seen, rather
than all 29,628 telemetry rows).

The delete then ran inside a `DO` block that compares the archived count and the
deleted count against an expected 779 and `raise exception`s on either mismatch,
so a wrong target set rolls back instead of committing:

```sql
do $$
declare expected_accounts constant int := 779; deleted_accounts int;
begin
  -- ... refuse unless archive.deleted_accounts holds exactly expected_accounts
  delete from public.app_state a using archive.deleted_accounts t
    where a.storage_key like 'u:' || t.id::text || ':%';
  delete from auth.users u using archive.deleted_accounts a where u.id = a.id;
  get diagnostics deleted_accounts = row_count;
  if deleted_accounts <> expected_accounts then
    raise exception 'Deleted %, expected % - rolling back', deleted_accounts, expected_accounts;
  end if;
end $$;
```

**`app_state` is the easy thing to miss.** It has no foreign key to
`auth.users`, so its 1,740 user-scoped rows (`u:<uid>:*`) do not cascade — they
would have sat there forever keyed to a dead uid. They were deleted in the same
transaction and their keys recorded in the archive.

### Step C — verification (all passed)

| Check | Result |
| --- | --- |
| Target accounts still in `auth.users` | 0 |
| Deleted emails still taken | 0 — every address released |
| Orphan `auth.identities` | 0 |
| Orphan profiles / enrollments / test history | 0 / 0 / 0 |
| Orphan `app_state` rows | 0 |
| `auth.users` / `profiles` totals | 587 / 587 |
| Admins remaining | 2 (owner + `testadmin@medbank.com`) |

A CSV roster (email, name, role, old MedBank ID, approval, providers, last
sign-in, data counts) was exported to the owner. It is deliberately **not**
committed — it is 779 students' personal data. It is the only way to map an old
MedBank ID to the new one someone gets on re-registration.

### Still open

The **hosted Google provider is still enabled.** The website hides the buttons
(`supabase.config.js -> googleOAuthEnabled: false`), but the Android app can
still sign in with Google — and doing so creates a fresh google-only account,
quietly undoing this cleanup one student at a time. Turning the provider off in
the Supabase dashboard (Authentication -> Providers -> Google) is the durable
fix; it is an auth change and was left for an explicit decision.
