# Admin layers: apply, verify, roll back

Written 2026-09-30. Super admins, and admins limited to areas (People, MCQ
Bank, Video Courses, Messaging, System). Design and reasoning: AGENTS.md
refactor log, "Admin layers" entry.

Nothing below has been applied to production yet. The agent that wrote it
was not allowed to run SQL on the hosted project, so every step is for the
owner. Everything was verified on a local Postgres copy (the relevant tables,
the existing admin policies, storage, the three RPCs): 46 permission checks
plus a full rollback-and-reapply round trip.

## Order

1. Database migration 1, then 2.
2. Edge Functions (5).
3. Merge the website PR.

Any order is safe for the two current admins (both are seeded as super
admins, and the website and functions treat a missing permissions table as
"everyone has full access"). But nobody is actually limited until **all
three** are done: the database stops direct writes, the functions stop
account changes, and the website hides pages. **Do not give anyone a limited
admin account until step 2 is done.**

## 1. Database

In the Supabase SQL editor (or `supabase db push --dns-resolver https`),
run, in this order:

1. `supabase/migrations/20260930030000_admin_permission_areas.sql`
2. `supabase/migrations/20260930030100_admin_area_enforcement.sql`

Check:

```sql
-- Both current admins are super admins.
select p.full_name, ap.is_super, ap.areas
from public.admin_permissions ap join public.profiles p on p.id = ap.user_id;

-- The new guard policies exist (expect 29*3 + 3 flags + 4 Hermes + 3 storage + 4 site access = 101).
select count(*) from pg_policies
where policyname like '%\_area\_guard\_%' or policyname like '%\_super\_guard%'
   or policyname like 'app\_state\_site\_maintenance\_%';

-- The three RPCs now check the Video Courses area.
select proname, prosrc like '%admin_has_area(''video_courses'')%' as patched
from pg_proc where proname in ('admin_generate_platform_course_coupons',
  'admin_disable_platform_course_coupon', 'admin_review_platform_course');
```

Then, signed in as yourself on the website, use any admin page as normal
(save a question, approve a student). Nothing should change for you.

## 2. Edge Functions

```bash
supabase functions deploy admin-create-user admin-delete-user \
  admin-set-user-access admin-set-user-password cloudflare-stream-tus-upload
```

These five were compared with the deployed versions before editing and
matched the repo exactly, so deploying them adds only the area checks.
`supabase/config.toml` keeps verify_jwt as it is today (off for the four
admin-* functions, on for the upload function).

**Do not deploy `send-push-notification` from this repo.** The deployed
version is newer (it comes from the Flutter repo and uses a shared
dispatcher); the copy here is stale. It needs no change: sending a push
requires an existing notification, and creating one already needs the
Messaging area.

## 3. Website

Merge the PR. Then, as a super admin: System → **Admin access**.

## Making a limited admin

1. Users → the user's ⋯ → Edit details → Role: Admin (super admins only).
2. System → Admin access → tick their areas → Save.

A new admin has no areas until step 2. They can always open the Dashboard.

## What a limited admin can and cannot do

- Can **read** every admin page's data (reads are not restricted), but the
  website only shows their areas.
- Can **change** only their areas' data. Outside them, updates/deletes affect
  0 rows and inserts are refused, whether from the website, the app or the API.
- Cannot touch admin accounts (create, promote, edit, suspend, delete),
  Site Access, Hermes, or Admin access.
- At least one super admin always remains: the database refuses the change
  that would remove the last one.

## Roll back

Run, in this order:

1. `supabase/rollbacks/20260930030100_admin_area_enforcement.sql`
2. `supabase/rollbacks/20260930030000_admin_permission_areas.sql`

The website and the Edge Functions keep working after a rollback (a missing
permissions table means full access for every admin).

## Known gaps (not fixed here)

- `app_state` global keys (`g:*`) can be written by anyone, even signed-out
  visitors. Only the Site Access key is now protected. The rest is a
  separate, older problem; fixing it means changing `app_state` RLS.
- `admin-agent-tool` (Hermes) keeps its own permission model; only super
  admins can now manage agents.
