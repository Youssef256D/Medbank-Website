# MedBank Admin Layer — Architecture & Flutter Implementation Guide

Everything needed to rebuild the web admin dashboard inside the Flutter mobile
app. Verified against the hosted project `fzjzjzdamehxbgikiskt` on 2026-08-05.

Companion docs: [`ARCHITECTURE.md`](ARCHITECTURE.md) (whole system),
[`NAMING.md`](NAMING.md) (**read this — the naming trap below will bite you**),
[`video-courses-mobile-integration.md`](video-courses-mobile-integration.md).

---

## 0. The single most important thing

**The admin dashboard has no backend of its own.** There is no admin API server,
no admin service, no business logic tier. The web app is a static file on GitHub
Pages holding only the public anon key. Every admin capability is one of exactly
two things:

| Path | Mechanism | Who authorizes |
|---|---|---|
| **A. Direct table access** | `supabase.from(table).select/insert/update/delete` with the admin's own session JWT | **Postgres RLS policies** |
| **B. Edge Functions** | `POST <project>/functions/v1/<fn>` with the admin's JWT as bearer | Function re-verifies the JWT + admin role, then uses the service-role key |

Path A covers ~90% of the dashboard. Path B exists only for the handful of
operations that require the `service_role` key — creating/deleting auth users,
setting passwords, banning accounts, sending push.

**What this means for Flutter:** you are not "calling the website's API." You are
a second, equal client of the same Postgres database. Anything the web dashboard
can do, Flutter can do with `supabase_flutter` and the same anon key — because
the permission lives in the database, not in the JavaScript.

**Corollary:** you cannot make Flutter more privileged by writing different
Dart code. If RLS says no, it's no. That is the security model working.

---

## 1. The naming trap (read before writing any query)

MedBank has **two unrelated products** that were both once called "Courses". This
is the single biggest source of implementation error in this codebase.

| You want | Table to query | Do NOT use |
|---|---|---|
| **MCQ Subjects** (question bank curriculum units) | `courses`, `course_topics` | — |
| **Video Courses** (the LMS: modules, lessons, video) | `platform_courses`, `platform_course_*` | — |

`public.courses` is **the MCQ subject list**, not the video LMS. Read-only alias
views `mcq_subjects` / `mcq_subject_topics` exist (with `security_invoker=true`)
if you want unambiguous names in Dart.

---

## 2. Auth and the admin gate

### 2.1 How admin is determined

One SQL function is the root of all admin authority:

```sql
private.is_admin_user()
  -- STABLE SECURITY DEFINER
  -- true when: profiles.id = auth.uid()
  --        AND profiles.role = 'admin'
  --        AND profiles.approved IS TRUE
```

Two things to internalize:

1. **`approved` matters.** An unapproved admin is not an admin. A row with
   `role='admin', approved=false` fails every admin policy.
2. **The client never decides this.** The web app's
   `if (user.role !== "admin") return "Access denied"` is *cosmetic only* — it
   hides UI. Someone bypassing it gains nothing, because every query is
   independently checked by RLS. **Do the same in Flutter: gate the UI for UX,
   and never treat that gate as security.**

### 2.2 Roles

`public.app_user_role` enum: `student`, `admin`, `creator`.

- `student` — normal user, gated by `approved` + `mcq_access_enabled` + `courses_access_enabled`
- `admin` — full control (this document)
- `creator` — owns Video Courses they author; submits for admin review. Never
  publishes or self-approves (enforced by a DB trigger, not by UI).

### 2.3 Sign-in

Standard Supabase Auth. Email/password, Google OAuth, Apple OAuth
(`appleOAuthEnabled: true`). In Flutter:

```dart
await Supabase.initialize(
  url: 'https://fzjzjzdamehxbgikiskt.supabase.co',
  anonKey: '<the anon key from supabase.config.js — public, safe to ship>',
);
final res = await supabase.auth.signInWithPassword(email: e, password: p);
final profile = await supabase.from('profiles')
    .select('id, role, approved, full_name, public_user_id')
    .eq('id', res.user!.id).single();
final isAdmin = profile['role'] == 'admin' && profile['approved'] == true;
```

**Never put the service-role key in the Flutter app.** It is not in the web app
either. If a feature seems to need it, it belongs in an Edge Function.

---

## 3. What NOT to copy from the web app

The web `main.js` is a ~47,000-line single-scope script with a large offline/sync
layer built up over time. **Most of it is accidental complexity you should not
reproduce.** Specifically:

### 3.1 Do not replicate `app_state`

`app_state` is a legacy key/value JSONB table (`g:<key>` global, `u:<uid>:<key>`
user-scoped). It predates the relational schema. It is now only a cache/offline
buffer. **Relational tables are primary and authoritative.** Flutter should read
and write the real tables and ignore `app_state` entirely.

### 3.2 Do not replicate the local-cache merge layer

The web app keeps a full local copy of every user, then reconciles it against
Supabase with `hydrateRelationalProfiles`, `shouldPreferRecentLocalUserData`,
`overlayConcurrentAdminUserWrites`, `scheduleRelationalWrite`,
`flushRelationalWrites`, per-user `profileUpdatedAt` stamps, and a
stale-snapshot overlay. This machinery exists to paper over a browser app that
wrote to a local store first and synced later. It has produced multiple
production bugs (approvals reverting to pending, roles being demoted on
write-back).

**In Flutter: query Supabase directly, show a loading state, write directly,
re-read.** You get correctness for free. Do not build a local mutable mirror of
the user list.

### 3.3 Do not copy the role coercion pattern

Historically 18 sites coerced `role` to `"admin" | "student"`, which silently
demoted creators on write-back. In Dart, model the role as a proper enum with an
explicit unknown→student fallback, and never write a role you did not read:

```dart
enum UserRole { student, creator, admin }
UserRole parseRole(String? v) => switch (v?.trim().toLowerCase()) {
  'admin' => UserRole.admin,
  'creator' => UserRole.creator,
  _ => UserRole.student,   // least privilege on anything unknown
};
```

---

## 4. Admin page inventory

The web dashboard is one route (`#admin`) with a sub-page switch. `state.adminPage`
∈ `dashboard, users, mcq-subjects, questions, bulk-import, notifications,
site-access, ai-agents, activity, logs, video-courses`.

| Page | Purpose | Primary data source |
|---|---|---|
| **dashboard** | Counts: users by role, students by academic year, registration trend, question totals by subject | `profiles` aggregate + `get_admin_question_count_summary()` |
| **users** | The main workhorse — search, approve/suspend, MCQ & Video access toggles, role, year/semester, course assignment, password reset, delete, create | `profiles`, `user_course_enrollments` + 4 Edge Functions |
| **mcq-subjects** | CRUD MCQ subjects and their topics | `courses`, `course_topics` |
| **questions** | CRUD MCQs, choices, images, publish/draft/archive | `questions`, `question_choices` |
| **bulk-import** | Paste/upload many questions at once | same, batched |
| **notifications** | Compose announcements, choose audience + deep-link destination, trigger push | `notifications` + `send-push-notification` |
| **site-access** | Global feature flags | `app_feature_flags` |
| **ai-agents** | Hermes admin assistant: agents, scoped permissions, approval queue, action log | `admin_agents`, `admin_agent_permissions`, `admin_agent_approval_requests`, `admin_agent_action_log` |
| **activity** | Live presence + session analytics | `user_presence`, `user_activity_sessions` |
| **logs** | Audit trail | `admin_agent_action_log` |
| **video-courses** | Full LMS admin: course tree, modules, lessons, enrollments, coupons, announcements, creator review queue | `platform_*` tables + admin RPCs |

**Suggested Flutter build order:** users → dashboard → notifications →
questions/mcq-subjects → video-courses → activity → ai-agents. The Users page
alone covers most day-to-day admin need.

---

## 5. Path A — tables you can hit directly

Every table below has RLS policies gated on `private.is_admin_user()`. With an
approved admin session, plain PostgREST calls work.

**Full CRUD (SELECT/INSERT/UPDATE/DELETE):**
`profiles`, `courses`, `course_topics`, `questions`, `question_choices`,
`notifications`, `notification_reads`, `app_feature_flags`, `admin_agents`,
`admin_agent_permissions`, `user_course_enrollments`, `user_presence`,
`user_activity_sessions`, `test_blocks`, `test_block_items`,
`test_history_entries`, `platform_courses`, `platform_course_modules`,
`platform_course_lessons`, `platform_course_resources`,
`platform_course_enrollments`, `platform_course_announcements`,
`platform_course_suggestions`

**Partial:**

| Table | Admin may |
|---|---|
| `admin_agent_action_log` | SELECT only (append-only audit trail) |
| `admin_agent_approval_requests` | SELECT, UPDATE (approve/deny — no insert) |
| `platform_course_enrollment_requests` | SELECT, UPDATE, DELETE |
| `platform_course_coupon_redemptions` | SELECT only (write via RPC) |
| `platform_course_module_entitlements` | SELECT only |
| `platform_lesson_progress` | SELECT, UPDATE, DELETE |
| `test_responses` | SELECT, DELETE |

### 5.1 Core column shapes

```
profiles          id uuid PK (= auth.users.id), public_user_id bigint!  ← short display ID, immutable
                  full_name!, email!, phone, role app_user_role!, approved bool!,
                  academic_year smallint, academic_semester smallint,
                  mcq_access_enabled bool!, courses_access_enabled bool!,
                  auth_provider, created_at!, updated_at!

courses           id uuid, course_code, course_name!, academic_year!, academic_semester!,
                  is_active!, created_at!, updated_at!            ← MCQ SUBJECTS

course_topics     id uuid, course_id!, topic_name!, sort_order!, is_active!

questions         id uuid, course_id!, topic_id!, author_id, stem!, explanation!,
                  objective, difficulty smallint!, status question_status!,
                  external_id, question_image_url, explanation_image_url, sort_order!

question_choices  id uuid, question_id!, choice_label!, choice_text!, is_correct!

notifications     id uuid, external_id!, recipient_user_id, title!, message!,
                  created_by, created_by_name!, is_active!,
                  target_route, target_mcq_subject, target_mcq_topic, target_video_course_id

app_feature_flags feature_key PK, enabled!, description, updated_by, updated_at!
```

### 5.2 Rules the database enforces (your UI must respect, not re-implement)

- **`questions.status`** is `draft | published | archived`. A question is only
  student-visible when published **and** it has ≥2 non-empty choices **and** ≥1
  correct choice. Enforce this in the Flutter editor as validation, but know the
  DB/queries are the real filter.
- **`question_choices.choice_label`** is whitelisted to `A`–`E`. Anything else is
  discarded.
- **`notifications.target_route`** has a CHECK constraint allowing only:
  `app-launcher`, `dashboard`, `create-test`, `analytics`, `video-courses`,
  `profile`, or NULL. **Do not send arbitrary URLs** — this constraint is
  deliberate defense against unsafe redirects. Adding a destination means a
  migration, not a client change.
- **`profiles.public_user_id`** is immutable (trigger-protected), sequential from
  100. Use it for admin search and display; UUIDs remain canonical for joins.
- **`test_history_entries`** are auto-pruned to 20 days by a cron job, and a
  trigger blocks writes older than the window.

---

## 6. Path B — Edge Functions (the privileged operations)

Base: `https://fzjzjzdamehxbgikiskt.supabase.co/functions/v1/<name>`

**Every call needs:**
```
Authorization: Bearer <the signed-in ADMIN's access token>
Content-Type: application/json
```

Each function independently: validates the JWT → loads the caller's `profiles`
row → requires `role='admin'` → only then uses the service-role key. Your Flutter
client is trusted exactly as much as the browser is: not at all.

**CORS is not a problem for Flutter.** The functions only *set*
`Access-Control-Allow-Origin` on responses; they never reject a request for
having a missing or unknown `Origin`. Native HTTP clients are unaffected.

### 6.1 `admin-create-user`

```jsonc
POST { "email", "password", "fullName", "role", "approved",
       "phone", "academicYear", "academicSemester" }
```
- `role` ∈ `student | creator | admin` (anything else → `student`)
- `approved` is honored only for `student`; admins and creators are always
  created approved
- `academicYear`/`academicSemester` are stored only for `student`
- password: 6–128 chars

Creates the Auth user with a confirmed email, writes the matching `profiles` row,
and bans the account if an unapproved student.

→ `200 {ok:true, ...profile}` · `400` validation · `401` bad token · `403` not admin

### 6.2 `admin-set-user-access` — **the approval endpoint**

```jsonc
POST { "targetAuthIds": ["uuid", ...], "approved": true|false }
// "targetAuthId" (singular) also accepted
```

**This is the one function you must not shortcut.** Approving a user is *two*
coupled writes:

1. `profiles.approved = true|false`
2. `auth.users` ban toggle — `ban_duration: "none"` when approved,
   `"876000h"` (~100 years) when suspended

If Flutter only updated `profiles.approved`, a suspended user would stay banned
and a newly approved user would remain locked out of Auth. **Always go through
this function.**

Returns `revertedProfileIds` — profiles whose `approved` flag was rolled back
because the Auth ban update failed (consistent-deny). Surface these; they mean
the operation did not fully succeed.

### 6.3 `admin-set-user-password`

```jsonc
POST { "targetAuthId": "uuid", "password": "..." }   // 6–128 chars
```
→ `200 {ok:true, updated:true}` · `404` target not found

### 6.4 `admin-delete-user`

```jsonc
POST { "targetAuthId": "uuid" }
```
Refuses self-deletion (`400`). Idempotent: already-gone →
`200 {ok:true, deleted:false, message:"User already removed."}`

### 6.5 `send-push-notification`

```jsonc
POST { "notificationId": "uuid" }   // the notifications row you already inserted
```
Flow: insert the `notifications` row first, then call this with its id. The
function resolves the audience (recipient / academic year / all), loads FCM
tokens, sends via FCM HTTP v1, and records each result in
`push_notification_deliveries` so retries skip successes.

Notes:
- Only delivers to devices of profiles created **at or before** the
  notification's `created_at` — new signups never receive old announcements.
- `{ok:false, error:"No registered devices match..."}` is a *normal* outcome, not
  a failure of the notification itself; the in-app row still exists.
- Firebase credentials live only in the Supabase secret
  `FIREBASE_SERVICE_ACCOUNT_JSON`. Never in the app.

### 6.6 Others

- `course-video-url` — signs Video Course media URLs (students + admin preview)
- `cloudflare-stream-token`, `cloudflare-stream-tus-upload` — deployed but
  **dormant** (`cloudflareStreamEnabled: false`); video falls back to Supabase
  Storage
- `admin-agent-tool` — the Hermes AI admin assistant backend

> **Deprecated:** `/api/*.js` (Node) mirrors some of these for an optional
> Vercel/Netlify host. `serverApiBaseUrl` is empty, so it is unused. **Do not
> call or extend it from Flutter.**

---

## 7. Admin RPCs (call via `supabase.rpc`)

```
get_admin_question_count_summary() → jsonb
    Per-subject question totals computed in Postgres (total / published /
    student-usable / blocked / draft / archived). Requires an APPROVED admin.
    Use this for dashboard counts instead of counting hydrated rows —
    the client never has the full question set.

admin_find_profile_by_public_user_id(p_public_user_id bigint)
    → TABLE(id, public_user_id, full_name, email, phone, role, approved,
            academic_year, academic_semester, courses_access_enabled)
    Admin user lookup by the short MedBank ID.

admin_review_platform_course(p_course_id uuid, p_approved bool, p_note text)
    → platform_courses     Approve or bounce a creator submission.

admin_generate_platform_course_coupons(p_course_id, p_coupon_type,
    p_module_ids uuid[], p_quantity int, p_expires_at, p_batch_name, p_note)
    → TABLE(coupon_id, coupon_code, code_preview, coupon_type, course_id,
            module_ids, expires_at, batch_name, created_at)
    *** Plain codes are returned ONCE, here, and never again — only hashes are
        stored. Present/export them immediately or they are unrecoverable. ***

admin_list_platform_course_coupons(course, type, status, search,
    created_from/to, redeemed_from/to, limit, offset)
    → TABLE(..., code_preview, status, redeemed_by, redeemed_name, total_count)
    Paginated; `total_count` is the window total for your pager.

admin_disable_platform_course_coupon(p_coupon_id uuid) → jsonb
admin_get_platform_course_coupon_stats(p_course_id uuid) → jsonb
```

---

## 8. Storage buckets

| Bucket | Public | Use |
|---|---|---|
| `question-images` | **yes** | MCQ stem/explanation images — direct public URL |
| `course-covers` | no | Video Course cover art — signed URL |
| `course-materials` | no | Lesson resources/attachments — signed URL |
| `course-videos` | no | Uploaded lesson video — **must** go through `course-video-url` |

Direct student SELECT on `course-videos` was deliberately removed. Always sign.

---

## 9. Traps that will cost you a day each

1. **`courses` ≠ Video Courses.** See §1. This has broken multiple agents.
2. **Approval is two writes.** Never set `profiles.approved` directly — §6.2.
3. **An unapproved admin is not an admin.** `is_admin_user()` requires
   `approved IS TRUE`. Test with a properly approved account.
4. **Roles: preserve, don't coerce.** Never map an unknown role onto `admin` or
   flatten `creator`. See §3.3 — this exact bug shipped and had to be fixed.
5. **`user_presence` / `user_activity_sessions` have
   `check (role in ('student','admin'))`** — writing `'creator'` there fails the
   insert. Report creators as `student` in telemetry only, or widen the
   constraint with a migration first.
6. **Question counts must come from the RPC.** Client-side counting is wrong
   because the client never holds all rows.
7. **`target_route` is constrained.** New deep-link destinations need a
   migration, not a client change.
8. **Schema changes go in `supabase/migrations/` only.** The root and
   `database/` `schema.sql` files are stale snapshots — reading them will
   mislead you. Apply with `supabase db push`.
9. **Cloudflare Stream is off.** Don't build against it.
10. **`framer-motion` in package.json is unused.** Irrelevant to you; noted so
    you don't chase it.

---

## 10. Recommended Flutter shape

```
lib/admin/
  data/
    admin_repository.dart      // ALL Supabase calls live here, nowhere else
    models/                    // Profile, Course, Topic, Question, Choice,
                               // Notification, PlatformCourse, Coupon...
  logic/
    admin_gate.dart            // role=='admin' && approved==true (UX only)
    users_controller.dart
    questions_controller.dart
    ...
  ui/
    admin_shell.dart           // nav: the 11 pages from §4
    pages/
```

Guidelines:

- **One repository.** Every table read/write and function call funnels through
  it. That is what makes the permission surface reviewable.
- **Server-side paging and filtering.** `.range()` + `.textSearch()`/`.ilike()`.
  Do not pull 1,288 profiles to filter in Dart — the web app's habit of holding
  everything locally is the thing to leave behind.
- **Read-after-write.** Especially for approval, role, and access changes.
- **Show the real error.** PostgREST returns a meaningful message; an RLS denial
  means the DB rejected it, and hiding that makes debugging impossible.
- **Realtime is available** on `content_versions` and others if you want live
  admin updates instead of polling. The web app polls every 30s.

### Minimal end-to-end example

```dart
// Approve a user — the correct way
Future<void> approveUser(String authId) async {
  final session = supabase.auth.currentSession!;
  final res = await http.post(
    Uri.parse('$fnBase/admin-set-user-access'),
    headers: {
      'Authorization': 'Bearer ${session.accessToken}',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'targetAuthIds': [authId], 'approved': true}),
  );
  final body = jsonDecode(res.body);
  if (body['ok'] != true) throw Exception(body['error']);
  if ((body['revertedProfileIds'] as List?)?.isNotEmpty ?? false) {
    throw Exception('Approval rolled back — auth update failed.');
  }
}

// Toggle MCQ access — plain table write, RLS authorizes it
Future<void> setMcqAccess(String profileId, bool on) =>
    supabase.from('profiles')
        .update({'mcq_access_enabled': on}).eq('id', profileId);
```

---

## 11. Current live state (2026-08-05)

- 1,292 profiles: 1,287 student · 4 admin · 1 creator
- 3,024 questions, all published and student-usable
- 52+ migrations, hosted DB in sync with the repo
- 9 Edge Functions deployed; `admin-create-user` at v6
- Auth: email/password + Google + Apple
