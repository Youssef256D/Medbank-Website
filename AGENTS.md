# AGENTS.md — MedBank

This file is the shared instruction guide for any AI coding tool working on this
repo (Codex, Antigravity, Zcode, Claude, Cursor, Windsurf, etc.). It states the
project's hard rules, the codebase layout, and a running log of refactors so the
next agent does not accidentally undo prior work or get confused by tooling.

> Read this file before editing. When you finish a change that other tools should
> know about, add an entry under **Refactor log** and/or **CHANGELOG.md**.

---

## 1. Hard rules (do not break these)

1. **The served site is a static SPA on GitHub Pages.** The committed files
   `index.html`, `main.js`, `bootstrap.js`, `supabase.config.js`, `styles.css`,
   and `sw.js` are served **as-is** with no build step in the deploy path. Do not
   introduce a runtime dependency on a bundler for the site to load — `main.js`
   must stay runnable as a plain classic `<script>`. (A build pipeline exists for
   optional minification, but the deploy does not use it — see §4.)

2. **Hosted Supabase is the single source of truth** for auth, courses,
   questions, progress, enrollments, and admin data. Browser storage is only a
   cache/UX layer (route memory, theme, offline pending writes).

3. **Never put secrets in frontend files.** `main.js`, `bootstrap.js`,
   `supabase.config.js`, and `index.html` may only contain the hosted project URL
   and the **publishable/anon** key. `SUPABASE_SERVICE_ROLE_KEY`, agent tokens,
   and any LLM provider keys belong only in `/api/*.js` (serverless) and
   `supabase/functions/*/index.ts` (Edge Functions).

4. **Schema changes go in migrations only.** Apply them to the hosted project.
   The root `schema.sql` and `database/schema.sql` files are **historical
   snapshots, not authoritative** (see §5). Do not edit them to change live
   schema.

5. **Keep `escapeHtml()` discipline.** Every user-controlled string interpolated
   into HTML must be wrapped in `escapeHtml(...)`. A full audit confirmed the
   current code is clean (see Refactor log 2026-06-18). The one field that looks
   unescaped — `choice.id` — is provably whitelisted to `A`–`E` by
   `normalizeQuestionChoiceLabel` before any render, so it is safe by
   construction. Do not regress this.

6. **Don't break the other tools.** This repo is worked on by multiple agents.
   Prefer additive, reversible changes. Document non-obvious decisions here and
   in `CHANGELOG.md`.

---

## 2. Codebase layout

```
index.html              App shell + head meta/SEO + theme bootstrap. Injects bootstrap.js.
bootstrap.js            IIFE loader. Loads supabase-js from CDN, handles OAuth
                        callback + native deep link, registers service worker,
                        then loads main.js as a classic <script>.
main.js                 THE SPA — ~47k lines, single flat module scope (NOT an
                        IIFE, NOT ES modules). Shared `state` object (line ~287),
                        central `render()` router (line ~19023) that switches on
                        `state.route` -> `renderXxx()` + `wireXxx()`. ~1,066
                        top-level function declarations.
styles.css              All styling (light/dark/comfort themes), ~15k lines.
supabase.config.js      window.__SUPABASE_CONFIG: URL, anon key, feature flags.
sw.js                   Service worker: precaches app shell, versioned cache,
                        offline fallback.

api/                    OPTIONAL Node serverless endpoints (admin actions). Uses
                        SUPABASE_SERVICE_ROLE_KEY. DEPRECATED in place — see §6.
  _supabase.js            Shared helpers (CORS, rate limit, auth, profile role).
  admin-delete-user.js
  admin-set-user-access.js
  admin-set-user-password.js

supabase/
  functions/            Deno/TS Edge Functions — CANONICAL admin path.
    admin-create-user/            } Live admin account endpoints used by
    admin-delete-user/            } GitHub Pages. /api/*.js mirrors only the
    admin-set-user-access/        } older delete/access/password path and is
    admin-set-user-password/      } deprecated in the current deploy (see §6).
    admin-agent-tool/   Hermes AI admin assistant (scoped + full-admin tools).
    cloudflare-stream-token/      Protected long-course-video pipeline.
    cloudflare-stream-tus-upload/
  migrations/           CANONICAL schema source of truth. Timestamped. Apply to
                        hosted project only (no local DB). See §5.
  optional_migrations/  Performance indexes that can be applied selectively.
  rollbacks/            Reverse SQL for selected migrations.

database/               Historical/reference copies. README here documents the
  schema.sql              hosted-DB model. schema.sql is a STALE snapshot (§5).
  migrations/           Older migration copies; superseded by supabase/migrations.

docs/                   Operational runbooks (e.g. supabase-disk-io-runbook.md).
Assets/                 Branding images.
```

### Routes (the `state.route` values the router handles)
- **Public:** `landing`, `mobile-app`, `mcqs`, `courses-platform`, `features`,
  `pricing`, `about`, `contact`
- **Auth:** `login`, `signup`, `forgot`, `reset-password`, `complete-profile`
- **Student app:** `app-launcher`, `courses`, `dashboard`, `notifications`,
  `create-test`, `session`, `review`, `analytics`, `profile`
- **Admin:** `admin` (sub-pages: dashboard, users, courses, questions,
  bulk-import, notifications, site-access, ai-agents, activity, logs,
  course-platform)

### Key invariants in `main.js`
- One shared mutable `state` object; one `appEl = #app`; one `render()`.
- `escapeHtml(value)` is the HTML-escaping helper (around line 40314). Use it
  for any dynamic string going into `innerHTML`.
- `normalizeQuestionChoiceLabel` whitelists choice ids to `A`–`E`; all choice
  rendering goes through `normalizeQuestionChoiceEntries` first.

---

## 3. Data model (hosted Supabase)

Core relational tables: `profiles`, `courses`, `course_topics`,
`user_course_enrollments`, `questions`, `question_choices`, `question_tags`,
`test_blocks`, `test_block_items`, `test_responses`, `notifications`, etc.
Plus the admin-agent control plane (`admin_agents`, `admin_agent_action_log`,
`admin_agent_approval_requests`) and the course learning-platform tables.

Enums: `user_role` (student/admin), `question_difficulty`, `question_status`
(draft/published/archived), `block_mode` (tutor/timed), `block_source`
(all/unused/incorrect/flagged), `block_status`.

RLS is enforced throughout. The browser uses only the anon key; every row-level
permission is in Postgres RLS policies, not in frontend code.

---

## 4. Build pipeline (optional, does NOT affect the live site)

A build pipeline is scaffolded but **not wired into the deploy**:

- `package.json` — devDependencies: `esbuild`, `eslint`. Scripts: `build`,
  `build:minify`, `lint`.
- `build/esbuild.config.js` — reads committed `main.js`/`bootstrap.js` and emits
  optional output to `dist/` (`*.built.js` by default, `*.min.js` via
  `build:minify`). Output filenames never collide with the served files.
- `eslint.config.cjs` — conservative lint config for syntax/correctness checks
  without imposing a large style refactor on the existing flat-script SPA.
- `dist/` is gitignored.

The committed, un-minified `main.js` remains the source of truth and what
GitHub Pages serves. Flipping the deploy to serve built output is a **separate,
explicit decision** that must also update `sw.js` precache paths and the
`bootstrap.js` script src. CI runs `npm run build` + `npm run lint` on every
push to keep the pipeline healthy, but the build artifacts are not deployed.

---

## 5. Schema source of truth

**Authoritative:** `supabase/migrations/*.sql` (applied to the hosted project).

**Non-authoritative snapshots (do not edit to change live schema):**
- `/schema.sql` (root) — historical snapshot of the early relational schema
  (21 tables). Missing everything added after Feb 2026 (`profiles`, course
  platform tables, `admin_agents`, etc.). Marked with a banner comment.
- `/database/schema.sql` — identical stale copy, also banner-marked.
- `/database/migrations/` — older migration copies; superseded by
  `supabase/migrations/`.

To change the schema: add a timestamped migration under `supabase/migrations/`
and apply it to the hosted project (`supabase db push --dns-resolver https`).
Do not start or depend on a local Postgres/Supabase instance.

---

## 6. Admin endpoints (canonical vs. deprecated)

**Canonical (used in production):** the Supabase Edge Functions
`supabase/functions/admin-create-user`, `admin-delete-user`,
`admin-set-user-access`, and `admin-set-user-password`. The frontend (`main.js`) calls these via
`<project-url>/functions/v1/admin-*`. When `supabase.config.js → serverApiBaseUrl`
is empty (the current GitHub Pages config), the `/api` Node path is never used —
the code always falls back to the Edge Functions.

**Deprecated (retained, not used in the current deploy):** `/api/admin-delete-user.js`,
`/api/admin-set-user-access.js`, `/api/admin-set-user-password.js`, and
`/api/_supabase.js`. These mirror the Edge Functions and exist only to support
an optional Vercel/Netlify hosting path where `serverApiBaseUrl` is set. Each
file carries a `@deprecated` header. Do not extend these; extend the Edge
Function instead. If you move the frontend off GitHub Pages to such a host, you
can reactivate them.

---

## 7. Refactor log (most recent first)

### 2026-09-10 — Signup refused emails that were actually free
Reported as "users try their old Google email, the site says it has been used
before, but as admin I cannot find that email". Both halves were true and the
cause was entirely client-side. Shipped as `2026-09-10.13`.

**Hosted state at diagnosis** (this is what ruled out every server explanation):
632 `auth.users` = 632 `profiles`, **0** auth rows without a profile, **0**
soft-deleted (`deleted_at`), **0** unconfirmed, 1 remaining Google identity.
Of the 779 archived accounts, 745 emails were still free and 34 had already
re-registered — the 34 were on a device or browser with no stale cache.

1. **The refusal came from `getUsers()`, before any network call.** The signup
   handler ran `users.some((user) => user.email.toLowerCase() === email)` and
   returned "Email already exists." `users` is the local
   `STORAGE_KEYS.users` cache. **`logout()` removes
   `STORAGE_KEYS.currentUserId` but never `STORAGE_KEYS.users`**, so a row
   survives the account it describes — and these accounts were deleted
   server-side while their owners' browsers kept the row forever. Nothing
   server-side can clear it, and the owner cannot log in to trigger a refresh,
   so it is permanent for that browser. The check is now gated on
   `!authClient`: with Supabase reachable it decides, per hard rule §2. The
   local-demo path keeps the guard because there is no server to ask.
2. **Deferring is safe because email confirmation is off** on this project (all
   41 signups since the cleanup have `email_confirmed_at <= created_at + 2s`).
   GoTrue therefore returns an explicit `User already registered` for a real
   duplicate rather than the obfuscated fake user it returns when confirmation
   is enabled, and the existing `toast(error.message)` surfaces it. **If email
   confirmation is ever turned on, revisit this** — `signUp` would then resolve
   with a fake user and no error, and the handler would fall through to a false
   "Account created" for a duplicate.
3. **`upsertLocalUserFromAuth()` matched that same stale row by email**, third
   in its fallback chain after `supabaseAuthId` and legacy `id`. Merging into
   it gave the new account the dead one's `publicUserId` (so the student would
   see their **old MedBank ID**, contradicting both the announcement and the
   server's freshly assigned value), its `createdAt`, cached `password`,
   approval stamps and `studentAccessIssue` — and `migrateLocalUserReferences()`
   would re-point the deleted account's local sessions and test history onto the
   new user. Fixing only the signup gate would have made all 745 of them hit
   this instead. An email-only match whose row carries a **different non-empty**
   `supabaseAuthId` is now treated as a recycled address: the stale row is
   overwritten in place rather than inherited from.
4. **A matched row with no `supabaseAuthId` is still merged** — that is the
   local-only account being upgraded to a real identity (2026-06-30). Do not
   collapse these two cases; the emptiness of `supabaseAuthId` is what
   distinguishes them.
5. **Deliberately not done: clearing `STORAGE_KEYS.users` on logout.** It would
   be the tidier root fix, but `logout()` flushes pending sync with
   `throwOnRelationalFailure: false`, so a failed flush would then discard an
   admin's unsynced user edits. The two fixes above make the staleness harmless
   at the points where it did damage. Revisit only with a deliberate decision
   about that flush.
6. **Verified** against the real shipped functions in the browser, with no
   account created on the hosted project. `upsertLocalUserFromAuth`: a recycled
   email yields `publicUserId: null`, a fresh `createdAt`, an empty password and
   no alias linking to the dead id, overwriting the stale row in place
   (1 row, not 2); a row with no `supabaseAuthId` still merges and keeps its
   `publicUserId`; the same account re-authenticating still merges. Signup:
   with a stale cached row for the exact email typed, the form reaches
   `signUp` and the only toast is Supabase's `User already registered` — it is
   no longer refused locally — and with the auth client stubbed to null the
   local guard still fires. `node --check` and `npm run lint` clean.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-09-10 — Auto-approval moved into the database
"Auto-approval is on but users are still not approved" was correct, and the
earlier badge work (same date, below) diagnosed only half of it. The sweep lived
**only** in `ensureAdminDashboardPolling()`, so it ran inside an admin's browser
while the admin dashboard was open and nowhere else. Proof on the hosted project:
three students with a valid phone, year 5 / semester 2 and five enrolments each
sat unapproved with `updated_at` still equal to `created_at` — nothing had ever
processed them. It looked intermittent because opening the dashboard approved
everyone in a batch.

Migration `20260910160000_server_side_student_auto_approval.sql` (rollback
provided) moves the decision into Postgres. **The client sweep is unchanged and
is now redundant rather than load-bearing** — do not delete it expecting a
behaviour change, and do not "fix" a perceived duplicate by removing the trigger.

1. **`profiles.auto_approval_blocked_at` is the load-bearing part, and the whole
   design turns on it.** `profiles.approved` is `NOT NULL DEFAULT false`, so a
   never-decided account and a deliberately suspended one are *identical* in the
   schema. A sweep that simply approved every complete-but-unapproved student
   would therefore re-approve anyone an admin suspended, on the next run —
   suspension would silently stop working. The trigger stamps this column when
   `approved` goes true -> false and clears it whenever `approved` is set true;
   both the trigger and the cron skip a non-null hold. **Never add another
   approval path that ignores this column.** Because the stamping lives in the
   trigger rather than in `main.js`, every client — website, Flutter app, admin
   agent, raw SQL — gets the protection without knowing about it.
2. **`private.student_phone_is_valid()` is a line-by-line port of
   `validateAndNormalizePhoneNumber()`**, including `normalizePhoneInput` and all
   eight `PHONE_COUNTRY_RULES` with the longest-dialling-code-first match order.
   It was **differential-tested against the real JS validator over 50 cases**
   (every country rule, both Egypt forms, the `00` prefix, punctuation, length
   boundaries, junk) with perfect agreement before the trigger was created. If
   the two ever diverge the admin Users page contradicts itself: the row badge
   from 2026-09-10 says "needs phone number" on an account the database already
   approved. Change them together.
3. **`private.student_profile_is_complete()` ports `hasCompleteStudentProfile` +
   `hasSelectedStudentCourses`**, including the rule that a valid term whose
   curriculum offers courses satisfies course selection on its own. It is
   SECURITY DEFINER because the trigger fires on a *student's own* profile write,
   and under RLS that student cannot read `public.courses`; a false negative
   there would silently withhold approval.
4. **Grant only, and never at the cost of the write.** Nothing here sets
   `approved` to false. The grant is wrapped in its own exception block so a
   fault in the eligibility check can never stop a student saving their profile.
   The trigger is BEFORE, mutating `NEW`, so there is no second UPDATE and no
   recursion. It is named to sort after `trg_profiles_assign_public_user_id` and
   before `trg_profiles_updated_at`, so `set_updated_at` still stamps the row and
   the admin poll's `skipIfUnchanged` change-detection keeps working.
5. **The `student_auto_approval` flag still governs both paths**, so the admin
   switch remains the off switch — verified in both directions.
6. **Cron `student-auto-approval` runs every minute** as a backstop for
   eligibility that becomes true without a profiles write of its own (an
   enrolment landing later, the flag being switched on, a course added to a
   curriculum). Confirmed firing: `succeeded`, 20 ms.
7. **Verified** with rollback-only transactions against real rows: suspension
   survives an unrelated later edit *and* a full cron sweep, and re-approving
   clears the hold; a profile becoming eligible is approved by the write itself
   with no cron and no admin; with the switch off neither path approves and the
   sweep returns 0. The three students waiting at the time (1.3 h, 0.2 h and
   2 minutes old) were approved. Afterwards: 618 approved, 3 pending, 0 eligible
   still pending. The 3 remaining have no phone at all — two are the Apple
   accounts that still cannot sign in to add one (see the entry below).
8. **The admin copy was corrected.** It still read "It runs while an admin
   dashboard is open", which is now false. Static cache bust: `2026-09-10.12`.

**Files touched:** `main.js`, `index.html`,
`supabase/migrations/20260910160000_server_side_student_auto_approval.sql`,
its rollback, `CHANGELOG.md`, `AGENTS.md`. Hosted: migration applied, cron job
scheduled, 3 students approved.

### 2026-09-10 — Mobile pop-up campaign admin surface
Adds **Pop-ups** to the existing admin data shell. Static cache bust:
`2026-09-10.11`. This website only administers mobile campaigns.

1. **The Flutter migration is the contract, and is still unapplied.** Read
   `../Medbank-App/supabase/migrations/20260910120000_app_popups.sql`; no SQL or
   Flutter files changed. Missing relations produce a calm migration panel and
   disable editing. Missing storage has its own migration explanation. Generic
   request failures do not expose raw database errors.
2. **`app-popups-utils.js` follows the video utility UMD pattern.** Browser
   namespace `MedBankAppPopups`, guarded in the admin renderer, loaded before
   `main.js`, precached, and included in lint. Its separate seven-route vocabulary
   includes `notifications`; the notification send path is unchanged. State
   resolution uses start-inclusive/end-exclusive windows, with inactive taking
   precedence. Validation rejects incompatible context and invalid CHECK values.
3. **Drafts start inactive.** Subject and course are optional destinations; a
   topic requires a subject. Switching routes clears incompatible context. Dates
   are entered in browser-local time and stored as ISO timestamps. Live edits
   and campaign deletion require confirmation. Writes explicitly allowlist
   campaign columns and verify a returned row; views are only ever selected.
4. **Artwork uploads use unique, non-upsert paths and public URLs.** PNG, JPEG,
   and WebP are accepted up to 5 MB, with under 1 MB recommended. Upload starts
   on selection; campaign save is separate. Removing/replacing an image or
   deleting a campaign does not delete storage objects, which may be reused.
   Preview mirrors the Flutter contain advert / cover banner distinction,
   hides advert text/buttons, and keeps the close position visible. CSS reuses
   existing light/comfort/dark tokens; no font-weight override was added.
5. **Metrics are unique accounts, not summed impressions.** Client aggregation
   reports shown (`seen_count > 0`), dismissed, tapped and tapped/shown percent.
   Dismissed and tapped can overlap. Campaign and view reads paginate with
   deterministic ordering until an empty page, including when the hosted row
   cap is smaller than the requested page size. Refresh updates status/metrics.
6. **`escapeHtml()` collapses `0` to an empty string, and a lenient test stub
   hid it.** The helper is `String(value || "")`, so `escapeHtml(0)` returns
   `""` — priority defaults to 0 and a new campaign has 0 impressions, so the
   first campaign an admin created rendered blank cells and an empty *required*
   priority input that blocked its own save. Numbers now go through
   `popupNumberText()` before being escaped. Do not "fix" this in `escapeHtml`
   itself: 525+ call sites depend on its falsy coercion, and `??` would start
   rendering `null` as the text "null". The reason the suite did not catch it is
   the more important half — the admin harness stubbed `escapeHtml` with `??`
   instead of `||`, making the mock more forgiving than production and blinding
   every falsy-rendering test. That stub now mirrors the real function exactly;
   keep the two in step, and check any new stub against the function it replaces.
7. **Only `Live` uses a coloured badge; the other three states are `neutral`.**
   The list exists to answer one question at a glance -- can students see this
   right now -- so `Live` is `badge good` and Scheduled, Ended and Inactive are
   all `badge neutral`. None of them is a fault: scheduled is queued, ended is
   finished, inactive is deliberately paused, and `badge bad` on any of them
   reads as an error report. The label already distinguishes the three.
   `state.adminPopupsMissing` is also cleared with its siblings on the admin
   state reset, so a stale missing-tables panel cannot survive a sign-out.
8. **Artwork is deliberately never deleted from storage.** Replacing an image or
   deleting a campaign leaves the object in `popup-images`. That is a choice,
   not an oversight: deletion is irreversible, the objects are capped at 5 MB
   and a handful per campaign, and an admin who has pasted a public URL
   elsewhere would have it broken from under them. Revisit only with a
   deliberate retention decision.
9. **Verification:** 38 Node tests pass, including utility boundary/targeting
   cases and isolated tests of the actual admin functions for missing tables,
   absent global, pagination, upload success/missing bucket, escaped preview,
   live-save cancellation, payload allowlisting and failed-write draft retention.
   Syntax checks, lint and build pass. Browser visual checks could not run:
   Aside was unavailable and browser security policy blocked the local file URL.
   No dev server, hosted writes, schema changes, staging or commits were used.

**Files touched:** `main.js`, `app-popups-utils.js`, `bootstrap.js`, `sw.js`,
`index.html`, `styles.css`, `package.json`, `tests/app-popups-utils.test.js`,
`AGENTS.md`, `CHANGELOG.md`.

### 2026-09-10 — Why a pending student is not auto-approved is now visible
Reported as "auto-approval is on but some users still are not approved". It is
working: on the hosted DB, recent signups are approved 27/27 and 7/7, and the
only 3 unapproved students of 613 all have `phone IS NULL`, which
`hasCompleteStudentApprovalProfile` correctly refuses. The defect was that
nothing said so — every message recited the same "phone number, year, semester,
and course selection" sentence whether one field was missing or all four.

1. **`describeMissingStudentApprovalFields(user)`** (with the other approval
   predicates) decomposes the exact checks inside `hasCompleteStudentProfile` /
   `hasSelectedStudentCourses` and returns `[]` whenever
   `hasCompleteStudentApprovalProfile` already passes. That early return is the
   invariant: a row can never name a blocker on an account the sweep would
   approve, or stay silent on one it would skip. Keep it in step if the approval
   rule changes.
2. **Course selection is suppressed until year and semester are both valid.**
   Below that, `hasSelectedStudentCourses` cannot consult the curriculum and
   falls through to the usually-empty explicit assignment list, so it would tell
   an admin to pick courses that setting the term supplies by itself. The badge
   re-evaluates live as the row is filled in.
3. **Row badge + specific messages.** Pending rows render "Not auto-approved —
   needs ..." under the MedBank ID, and the four generic toasts now call
   `summariseMissingApprovalFields()` over the accounts actually skipped. The
   admin row already has an inline phone input, so the badge points at the fix.
4. **`--data-warn` was the wrong token and is a trap.** It is declared once at
   `:root` and never re-declared per theme, so it is frozen to the light palette
   exactly like `--text` (see 2026-09-10 login-notice entry). `--danger` is
   themed but `theme-comfort` sets it to `#ef4444`, a light red for dark
   surfaces, which measured **3.14:1** on comfort's parchment card. New
   `--approval-gap-fg` carries a complete palette: `#99201f` at `:root` (comfort
   inherits it) and `#f87171` under `theme-dark`. Measured 8.14 / 6.79 / 6.54:1
   in light / comfort / dark.
5. **Do not add another `font-weight` `!important`.** `html body :where(*, ::before, ::after)`
   forces `400 !important` app-wide, with opt-in allowlists below it. The badge
   joins the existing medium-emphasis `:is(...)` list instead of competing.
6. **Two of the three stuck accounts cannot self-heal, and this is not fixed
   here.** They are Apple sign-ins: Apple never returns a phone, and
   `appleOAuthEnabled: false` (2026-08-09) removed the Apple button, so they
   cannot log in to reach `complete-profile` (which does collect a phone). They
   have no password identity either. Same lockout shape as the Google cohort.
   Unblocking needs an owner decision — set a password for them (the row's
   **Set password** button is only hidden for `google`, so it works on Apple),
   or re-enable the Apple provider. The third is a legacy `invite_code` email
   signup that can log in and will be routed to `complete-profile` on its own.
7. **Verified** by lifting the real predicates into a Node harness (23 checks:
   the three real account shapes, the never-contradict invariant in both
   directions, per-field accuracy, term-gated course suppression, non-students,
   null input, and the aggregate wording) and by driving the admin Users page:
   badges match the hosted rows exactly, the eligible pending account gets none,
   a badge narrows as fields are filled and clears on completion, the sweep then
   approves that account, and bulk approve now reports the real blockers.
   Contrast measured in all three themes. `node --check` and `npm run lint`
   clean. Static cache bust: `2026-09-10.09`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-09-10 — Brand assets regenerated from the current logo files
Link previews and favicons were still serving the previous MedBank mark. All of
it is now generated from `Assets/Fav icon.png` (2048x2048, transparent) and
`Assets/web Logo.png` (2528x1696, transparent) - **those two are the sources of
truth; regenerate from them rather than hand-editing anything in
`Assets/branding/`.** Shipped as `2026-09-10.05`.

1. **Both sources carry real alpha and a lot of empty margin.** Their content
   bounding boxes are 1387x1084 and 1569x474. Everything below is trimmed to the
   alpha bbox first and then re-padded deliberately - resizing the raw files
   gives a glyph that is illegible at 32px.
2. **Generated:** `favicon.png` (512), `favicon-192x192.png`, `favicon-32x32.png`
   - transparent, glyph at 86% of the canvas; `apple-touch-icon.png` (180)
   flattened onto white at 76%, because iOS composites transparency onto black
   and rounds the corners itself; `medbank-logo.png` (1400x423, transparent),
   which is what the privacy/deletion page `<img>` and the JSON-LD logo point at;
   and `og-image.png` (1200x630, opaque white), the Open Graph card.
3. **`og-image.png` is opaque on purpose.** Several preview clients render a
   transparent PNG on black. It is also the standard 1.91:1 - the old tag pointed
   at the 1400x939 logo, which is why previews cropped it into a square. `og:image`
   and `twitter:image` in `index.html` and `privacy.html` now point at it, with
   explicit `og:image:width`/`height`/`type`.
4. **The manifest's maskable icons were wrong and are now split.** Every icon was
   declared `"purpose": "any maskable"` while being transparent with the glyph at
   full bleed - Android crops a maskable icon to its own shape and fills the rest
   with black. The transparent icons are now `"any"`, and new `maskable-192.png` /
   `maskable-512.png` are opaque white with the glyph at 58% so it survives the
   safe-zone crop. Do not re-merge those purposes.
5. **`favicon-32x32.png` existed but was never linked** - added to `index.html`,
   `privacy.html` and `deletion.html`. Browsers prefer it for the tab strip.
6. **`sw.js` precache** gained the 32px favicon and both maskable icons. The
   cache name is keyed on the version query, so the cache-bust re-fetches the
   replaced image files; no separate invalidation is needed.
7. **Left alone:** `Assets/branding/medbank-logo.svg` (old artwork, referenced by
   nothing served), `favicon-source.png`, and `web-logo-hero.png`, which is a
   default course cover in `main.js`, not branding.
8. **Verified** in the browser: all eight files load at their intended
   dimensions, `og:image` resolves to the 1200x630 card, the four icon links and
   the four manifest entries resolve, and the manifest is valid JSON.

**Files touched:** `Assets/branding/*` (regenerated), `index.html`,
`privacy.html`, `deletion.html`, `manifest.webmanifest`, `sw.js`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-09-10 — Login notice, signup cleanup, dark mode paused
Frontend batch shipped as `2026-09-10.04`. No auth, access, RLS, or sync
behaviour changed.

1. **`googleMigrationNoticeHtml()` + `hasDismissedGoogleMigrationNotice()`**
   (defined just above `renderAuth`) render a one-time panel at the top of the
   login card, dismissed via `medbank_google_migration_notice_v1` in
   `localStorage`. **Browser-scoped and dismissal-based on purpose:** the reader
   is signed out so there is no user row to record against, and a notice that
   burned itself on first render would fail exactly the person who opened the
   page and left without reading. Both storage calls are wrapped in try/catch —
   a private window that throws re-shows the notice rather than hiding it.
2. **`.auth-notice` CSS is deliberately not token-based.** It lives inside
   `.auth-public-card`, which stays `rgba(255,255,255,0.9)` in all three themes,
   while `--ink`, `--muted`, `--brand` and `--brand-soft` all flip to light
   values under `body.theme-dark` — that combination rendered near-white text on
   a white card. The card itself dodges this by using `var(--text)`, which
   resolves once at `:root` and is therefore **frozen to the light palette**
   (note: the 2026-07-05 entry claims these aliases follow the active theme;
   they do not, and `--text` reading `#102a43` while `--ink` reads `#f5f5f5`
   under `theme-dark` is the proof). The notice uses fixed light-surface colours
   instead. Its button selectors are prefixed with `body` because
   `body.theme-dark .btn.ghost` is (0,3,1) and outranks `.auth-notice .btn.x`
   at (0,3,0).
3. **Invite code deleted from signup** — the field, the `data.get("inviteCode")`
   read, and the `STORAGE_KEYS.invites` check. It validated against two seeded
   demo codes in browser storage, had no admin UI, and never reached the
   profile. `STORAGE_KEYS.invites` and its seed are left in place: they are
   inert once nothing reads them, and the key appears in two sync-key lists that
   are not worth disturbing for a dead field.
4. **Phone examples moved from the signup subtitle to the input placeholder**
   in both signup variants (normal and the Google-onboarding flow). The full
   list clips on narrow phones, showing the first two formats — accepted
   trade-off for putting the hint where it applies.
5. **`THEME_DARK_ENABLED = false`** (next to `THEME_COMFORT`) pauses dark mode
   in four places: `getStoredThemePreference` resolves a stored `dark` to light,
   the `toggle-theme` cycle skips it, both button-label paths, and `applyTheme`
   as a last-resort guard. **The `index.html` first-paint bootstrap has its own
   copy of this guard and must stay in sync** — without it a browser holding a
   `dark` preference flashes a dark first paint before `main.js` corrects it.
   Restore dark by flipping both flags; nothing was deleted.
6. **`body .panel.auth-public-shell` strips the outer auth frame.** The auth
   routes render `.auth-public-card` inside a `.panel.auth-public-shell`, so the
   card sat inside a second painted box on login and signup. The shell keeps its
   grid (marketing copy beside the card) and drops background, border, radius,
   shadow, backdrop-filter and padding. The `body` prefix is load-bearing:
   `body.theme-dark .panel` / `body.theme-comfort .panel` are (0,2,1) and repaint
   background + box-shadow, so a plain `.panel.auth-public-shell` at (0,2,0) lost
   to them and the frame survived in those two themes. At (0,3,1) it also beats
   the `.auth-public-shell` padding/radius inside the <=640px block, since media
   queries add no specificity.
7. **`offerPasswordToBrowserManager()` (just above `wireAuth`) makes password
   managers offer to save.** Every auth form calls `preventDefault()` and the
   route re-render then removes the form from the DOM, so Chrome/Edge saw no
   submission and never prompted. The helper calls
   `navigator.credentials.store()` with a `PasswordCredential`. Wired at four
   sites: password login, the offline/local login fallback (real accounts land
   there when Supabase is unreachable, not just demo ones), signup (placed
   before the approved/awaiting-approval branch so it covers both), and the
   password-reset success path so the stored entry gets updated.
   - **Callers deliberately do not await it.** The prompt is browser chrome and
     survives the re-render; blocking sign-in behind it buys nothing. The helper
     swallows every error and attaches its own `.catch()`, so a dismissed prompt
     can never fail a login or raise an unhandled rejection.
   - **Safari and Firefox do not implement `PasswordCredential`** and fall back
     to their own heuristics. That is why the auth forms must remain real
     `<form>` elements carrying `autocomplete="username"` /`"current-password"` /
     `"new-password"` — on those browsers the attributes are the only signal.
     Do not remove them.
   - `window.isSecureContext` is required by `store()`; localhost qualifies.
8. **The CSP inline-script hashes were recomputed** because the theme bootstrap
   changed. When you do this, mask HTML comments first: the CSP maintenance note
   at the top of `index.html` contains a literal `<script>` that a naive regex
   matches, which swallows the JSON-LD block and silently drops its hash.
   Verified afterwards that every inline script's hash is present in the
   directive and that only the edited script's hash moved.
9. **Verified** in the browser at desktop and 375px: notice renders, dismiss
   persists across reload, *Create account* navigates and counts as
   acknowledged; legible in light, dark and comfort (dark checked before it was
   paused); signup has no invite field and the placeholder carries the formats;
   a stored `dark` preference resolves to light with no dark first paint; the
   toggle alternates light/comfort and never reaches dark; the auth shell
   reports no background, shadow, border or padding on both routes in light and
   comfort. Credential storage was exercised end to end - a real form submit
   reaches `navigator.credentials.store()` with the typed email, the password
   and the account name, and the app still routes to app-launcher - plus every
   guard: no `PasswordCredential` (Safari-like) returns false, missing
   email/password returns false, and a rejecting `store()` neither throws nor
   leaves an unhandled rejection. `node --check` and `npm run lint` clean.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`, `docs/announcements/2026-09-10-google-account-migration.md`.

### 2026-09-10 — 779 Google-registered accounts archived and deleted
Every account that could sign in with Google was removed from Supabase Auth so
its email address is released for email+password re-registration: 777 students
(661 google-only, 116 google+password) and 2 admins. `code.youssefaayoub@gmail.com`
was excluded by name and still has admin access; `testadmin@medbank.com` was
never in scope. **This was data, not schema or policy** — no RLS, gating column,
or served file changed.

1. **`auth.identities` is the ground truth for "is this a Google account",
   not `profiles.auth_provider`.** That column comes from a one-time backfill
   (`20260218054626`) and is best-effort thereafter, so it can be stale or null.
   Every query here joined `auth.identities`.
2. **The delete targets `auth.users`, nothing else.** `profiles.id` is
   `REFERENCES auth.users(id) ON DELETE CASCADE` and eight tables cascade from
   `profiles`, so one delete removes the graph. Deleting the `profiles` row
   alone would *not* release the email — the `auth.users` row still holds it and
   signup keeps failing with "already registered".
3. **`archive.deleted_accounts` (migration `20260909224007`) is the record.**
   Each account was snapshotted as JSONB immediately before deletion: auth user
   + identities, full profile, enrollments, test history, blocks and items,
   platform enrollments and lesson progress, notifications and reads, device
   tokens, presence, `app_state` keys, and an activity-session summary. The
   `archive` schema is **not** in the PostgREST exposed schemas and the table has
   RLS on with no policies, so anon/authenticated cannot reach it. It is an audit
   record, not an undo button — restoring would mean new auth ids and remapping
   every `user_id`.
4. **`app_state` has no FK to `auth.users`.** 1,740 user-scoped rows (18 MB,
   keys `u:<uid>:*`) would have been left orphaned behind the deleted accounts,
   so they were deleted in the same transaction. Their keys are in the archive.
   Any future account-deletion path must do this too, or it leaks rows.
5. **Two FK groups can block a delete like this** and were checked first:
   `platform_course_coupon_redemptions.user_id` and the three
   `platform_course_coupons` provenance columns are RESTRICT against `profiles`.
   Zero targets held any, so the delete ran clean. Check them again next time —
   a coupon redemption will abort the whole statement.
6. **The delete ran inside a `DO` block that raises on a row-count mismatch**,
   so a wrong target set rolls back rather than committing. Verified after:
   0 targets remain, 0 of the 779 emails still taken, 0 orphan identities,
   profiles, enrollments, test-history, or `app_state` rows; `auth.users` and
   `profiles` both 587.
7. **Not done, and it matters:** the hosted **Google provider is still enabled**.
   The website hides the buttons (`googleOAuthEnabled: false`, 2026-09-06) but
   the Android app can still sign in with Google, which would recreate a
   google-only account and undo this. Disabling the hosted provider is an auth
   change under rule §1 and needs explicit confirmation.

**Files touched:** `supabase/migrations/20260909224007_add_account_archive.sql`,
its rollback, `docs/delete-google-users-runbook.md`, `CHANGELOG.md`, `AGENTS.md`.
Hosted data: 779 Auth users archived and deleted, 1,740 `app_state` rows removed.

### 2026-09-09 — Auto-approval switch on the admin Users page
Adds an **Auto-approve** switch beside *Approve all pending*. While it is on,
each admin dashboard poll approves the pending students who already qualify.

1. **One eligibility rule, one write path.** `approveEligiblePendingStudents()`
   (next to the approval predicates) is now the whole body of both the
   *Approve all pending* click handler and the automatic sweep. Do not
   reimplement either side: the button and the sweep must never be able to
   disagree about who qualifies (`hasCompleteStudentApprovalProfile`, per
   2026-09-05) or about how approval is written (relational profile update,
   then `syncAdminAccessChangeNow`). The handler keeps only what is genuinely
   its own — the confirm dialog, the busy flag, and the toast.
2. **`syncEnrollmentRows` is a parameter, not a dependency.** That row save is
   DOM-driven and lives inside `wireAdmin`, so only the button can pass it. The
   sweep passes nothing and instead refuses to run while any row draft is
   unsaved, so it only ever acts on stored profile data — it can never approve
   an account out from under an admin who is mid-edit.
3. **The sweep is deliberately admin-session-driven.** It runs from
   `ensureAdminDashboardPolling()`; with no admin dashboard open, nothing is
   approved. Approving without an admin present would mean writing to the
   approval gate from the database itself (a trigger or cron on
   `profiles.approved`), which is a separate decision under rule §1 and was
   explicitly not taken here.
4. **`canRunStudentAutoApprovalSweep()` is the safety gate**, and every clause
   in it is load-bearing: flag on, current user is an admin, no manual bulk
   action or force refresh running, no sweep already in flight, no unsaved row
   drafts or settling saves, no active admin user mutation or its cooldown, and
   a 15s minimum between sweeps. Do not relax these to make it feel snappier —
   the toggle already fires an immediate sweep on enable.
5. **The flag is a site setting, not local state.** `app_feature_flags` ->
   `student_auto_approval`, whose existing RLS already limits select/insert/
   update to admins, so a non-admin cannot enable auto-approval even by calling
   the helper (verified: the write is rejected with a row-level security error
   and the switch stays off). A failed *read* leaves the last known value rather
   than defaulting to on. A missing row reads as off.
6. **No schema, policy, or gating change.** Migration
   `20260909101500_add_student_auto_approval_feature_flag.sql` only seeds the
   flag row (`on conflict do nothing`); the app upserts it anyway, so applying
   it is optional and the feature works without it. Rollback provided.
7. **Verified** by lifting the real predicates into a Node harness (16 account
   shapes; pending/eligible partition, subset, agreement with the Users
   approval filter, and each missing field held back) and the real sweep guard
   into a second harness (16 blocking conditions), and by driving the running
   admin Users page: switch renders and toggles, an eligible pending student is
   auto-approved with the same stamps as the manual path, an incomplete one is
   untouched, the refactored button still refuses incomplete-only batches and
   still reports skipped counts, and a non-admin write is refused by RLS.
   `node --check` and `npm run lint` clean.
8. **Static cache bust:** `2026-09-09.03-local` (drop `-local` before shipping).

**Files touched:** `main.js`, `index.html`,
`supabase/migrations/20260909101500_add_student_auto_approval_feature_flag.sql`,
`supabase/rollbacks/20260909101500_add_student_auto_approval_feature_flag.sql`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-09-06 — Home page improvements and layout alignment
Changes on branch `homepage-improvements`:
1. **First-paint parity in `index.html`**: `index.html` previously omitted `#landing-mcqs`, `#landing-courses-platform`, and `#landing-contact`, causing noticeable layout shift when `renderLanding()` executed and leaving topbar links with missing targets before JS evaluation. All 5 sections are now pre-rendered.
2. **Sticky header scroll offset**: `.landing-scroll-section` now includes `scroll-margin-top: 5.5rem`, preventing section titles from sliding beneath the sticky `.topbar`.
3. **Dynamic hero state & explore links**: Authenticated users viewing the landing page see "Open MedBank" and "My profile", while visitors see "Log in" and "Sign up". Quick-jump anchors (`[data-scroll-to]`) allow direct exploration of the key sections.
4. **Footer copyright**: Added copyright notice to both static shell and `marketingFooterHtml()`.
5. **Static cache bust**: `2026-09-06.02`.

### 2026-09-06 — Google sign-in hidden on the website
`supabase.config.js -> googleOAuthEnabled` is now `false`, mirroring the
`appleOAuthEnabled` pattern from 2026-08-09. This is **UI visibility only** —
the hosted Google provider, `startGoogleOAuthSignIn()`, the OAuth callback in
`bootstrap.js`, and the `complete-profile` onboarding route are all untouched,
so existing Google accounts still sign in and the mobile app is unaffected.
Restore the website buttons by flipping only this flag.

1. **The empty OAuth row is removed, not just the button.** Both the login and
   signup forms wrap the whole `.auth-oauth-row` (plus login's `or` divider and
   signup's `or sign up with email` divider) in a
   `googleOAuthEnabled || appleOAuthEnabled` guard. With both providers off the
   markup would otherwise render an empty flex row and a stray divider.
2. **Wiring needed no change.** `wireAuth()` already reads both buttons with
   `document.getElementById(...)` and attaches via `googleButton?.
   addEventListener`, so an absent button is a no-op.
3. **Signup copy follows the flag.** "Use Google or sign up with email." becomes
   "Sign up with email." when Google is hidden; the phone-format examples are
   unchanged.
4. **Static cache bust:** `2026-09-06.01`.

**Files touched:** `main.js`, `supabase.config.js`, `index.html`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-09-05 — Admin Users list filters by approval status
Adds an **Approval** select to the admin Users filter form, following the
existing year/semester pattern exactly (`state.adminUserFilterApproval` →
`matchesAdminUserFilters` → render).

1. **One predicate, three consumers.** `matchesAdminUserApprovalFilter()` (next
   to `matchesAdminUserFilters`) is built on `isUserAccessApproved`, the same
   function behind the pending count and **Approve all pending**, so the filter
   can never disagree with those. Do not "simplify" it to read `isApproved`
   directly: `isUserAccessApproved` also reports a student with an incomplete
   profile as not approved even when `isApproved` is true, and those accounts
   are exactly the ones an admin needs to find.
2. **Buckets.** `pending` = `!isUserAccessApproved`; `approved` = its
   complement (the two partition the list); `incomplete` = pending **and**
   `!hasCompleteStudentApprovalProfile`, a strict subset of pending that
   isolates the accounts bulk approve skips (see 2026-08-11). Admins and
   creators are approved by construction unless explicitly unapproved, and
   non-students are never "incomplete".
3. **Unknown values are ignored, not empty.** `normalizeAdminUserApprovalFilter`
   whitelists to `ADMIN_USER_APPROVAL_FILTERS`, so a stale or hand-edited value
   falls back to "all accounts" rather than filtering everything out.
4. **Filtering happens before `ADMIN_USER_RENDER_LIMIT`**, so this is what makes
   pending accounts reachable in a long user list rather than a cosmetic filter.
5. **Selection is not cleared on filter change** — the render path already
   prunes `adminSelectedUserIds` to visible rows via `normalizeAdminUserIdList`,
   so clearing would only lose still-valid selections.
6. **No new CSS.** The field reuses the form's existing `.form-row` grid and
   stacks full-width on mobile.
7. **Verified** by lifting the real predicates into a Node harness (7 account
   shapes; partition, subset, and unknown-value invariants) and by driving the
   live admin Users page: All 6 → Not approved 1 → Approved 5 → back to 6, with
   the reset button enabling and disabling correctly. The `incomplete` bucket
   was exercised against synthetic objects through the shipped in-page
   functions, because the only hosted accounts available are real student rows.
8. **Static cache bust:** `2026-09-05.02`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-09-05 — Android app released; Google Play card is now a real link
The mobile app section was built with all three store cards deliberately
non-clickable (2026-08-03) because no listing URL existed. The Android build is
now published, so the Google Play card is an `<a>` to
`https://play.google.com/store/apps/details?id=medbank.com`
(`GOOGLE_PLAY_APP_URL`, defined just above `landingMobileAppsSectionHtml()`),
opening in a new tab with `rel="noopener noreferrer"`.

1. **One shared source, two copies.** `landingMobileAppsSectionHtml()` feeds
   both the homepage `#landing-mobile-app` section and the standalone
   `renderMobileAppPage()` route, so the SPA needed one edit — but the static
   `index.html` first-paint fallback mirrors the same markup and had to be
   edited to match, or the released badge would flicker back to "coming soon"
   on every load. Keep those two in sync.
2. **The other two cards are untouched.** App Store and Huawei AppGallery stay
   `<div role="listitem">` with coming-soon copy. Only the Google Play card
   carries `is-live`.
3. **Copy changes.** Status pill "Mobile apps · Coming soon" → "Android app ·
   Out now on Google Play"; card "Coming soon on / Google Play" → "Get it on /
   Google Play" with an "Available now" dot replacing the "Android" platform
   label; access note "Free to download" → "Free on Google Play". The section
   `aria-label` dropped "coming soon".
4. **CSS is appended at the end of `styles.css`**, token-based so all three
   themes work: `a.lp-store-card` resets link color/decoration, `.is-live`
   gives the brand-tinted surface and filled icon, and hover/`:focus-visible`
   states are gated behind `prefers-reduced-motion`.
5. **Static cache bust:** `2026-09-05.01`.

**Files touched:** `main.js`, `index.html`, `styles.css`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-08-11 — Stored phone/term details are no longer discarded on read
Signup details "not being recorded" was a **read** bug, not a write bug, plus a
cross-client validator mismatch. Do not re-introduce either drop.

1. **A stored phone this app cannot validate was thrown away.** Both
   `refreshCurrentUserFromRelationalProfile` (~L4647) and
   `hydrateRelationalProfiles` (~L9749) did
   `validation.ok ? validation.number : ""`, so any `profiles.phone` the website
   validator rejects resolved to empty. The admin row then rendered an empty
   phone input, and the next row save wrote `phone: null` back to Supabase —
   the student's number was erased. The Flutter app
   (`Medbank-App/lib/features/auth/models/student_profile_details.dart`)
   accepts *any* value with 8+ digits and ≤20 characters, so mobile signups
   store formats like `1004532728` or a landline that
   `validateAndNormalizePhoneNumber` rejects. That is the "some users" cohort.
   New `resolveStoredPhoneValue()` keeps the raw stored text when it cannot be
   normalized; a valid number still wins over a raw one from either source.
   Approval gating is unchanged — `hasCompleteStudentProfile()` still requires a
   valid number — so the admin now *sees* the bad number and can fix it instead
   of being told the student never entered one.
2. **A half-filled term resolved to no term at all.** Year and semester were
   gated on `hasProfileEnrollmentTerm` (both non-null) before either was used,
   so a profile with a year but no semester showed neither. New
   `resolveEnrollmentTermPair(primary, fallback)` prefers a complete pair from
   either source and only then falls back to whichever single values exist. Both
   hydration paths use it.
3. **Not fixed here:** the two clients still disagree on what a valid phone is.
   The durable fix is to align the Flutter validator with
   `validateAndNormalizePhoneNumber`, or to relax this one. Until then the
   website preserves and displays what the app stored.
4. **Verified** with a Node harness that lifts the real helpers out of `main.js`
   (12 cases: valid/normalizing formats, mobile-app formats this validator
   rejects, empty input, and all six term-pairing combinations). `node --check`
   and `npm run lint` clean. Static cache bust: `2026-08-11.02`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-11 — Bulk approve tolerates incomplete accounts
`syncEnrollmentRowsForUserIds()` saves every selected admin Users row before a
bulk approve. It previously returned `false` on the first row that failed to
save — including the "Approved students need a valid phone number, year,
semester, and course selection" case — which aborted the whole batch, so a
single incomplete account blocked approving everyone else.

It now returns `{ ok, failedUserIds }` and takes `tolerateRowFailures`. Both
bulk-approve call sites pass it: unsaveable rows are recorded and skipped, the
flush still fails the whole action (`ok: false`). `saveUserEnrollmentFromRow()`
gained `suppressValidationToast` so the batch does not emit one toast per bad
row. The confirm dialog and the result toast now state how many accounts were
skipped and what is missing. Eligibility itself is unchanged —
`hasCompleteStudentApprovalProfile()` is still the gate, so no incomplete
student is approved. Static cache bust: `2026-08-11.01`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-09 — Coupon foreign keys no longer block Video Course deletion
`adminDeletePlatformCourse()` correctly issued a direct `platform_courses`
delete, but migration `20260804205400` made both
`platform_course_coupons.course_id` and
`platform_course_coupon_redemptions.course_id` restrictive. Any course with a
coupon therefore failed before the existing module/lesson/enrollment cascades
could run.

Hosted migration `20260809114410_fix_platform_course_coupon_delete_cascade.sql`
changes the two direct course edges to `ON DELETE CASCADE`. Coupon provenance
edges from redemptions, enrollments, and module entitlements are now `NO ACTION
DEFERRABLE INITIALLY DEFERRED`: direct coupon deletion is still rejected, but a
course deletion can remove both sides of those relationships before the check
runs at transaction end. Partial indexes on the two previously unindexed
`source_coupon_id` columns keep FK checks and cascades fast. The admin warning
now names coupons and redemption records explicitly.

Verified on the hosted project with rollback-only synthetic data covering a
redeemed coupon, full-course enrollment, and module entitlement. Course delete
cascaded the full graph, direct coupon deletion remained protected, and zero
test rows remained. Static cache bust: `2026-08-09.02`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`,
`supabase/migrations/20260809114410_fix_platform_course_coupon_delete_cascade.sql`,
and its matching rollback.

### 2026-08-09 — Apple sign-in hidden; stale no-contact test users removed
`supabase.config.js -> appleOAuthEnabled` is now `false`, which removes the
Apple buttons from login/signup while leaving the configured hosted provider
and `startAppleOAuthSignIn()` path intact. Restore the website UI later by
flipping only this flag. Static cache bust: `2026-08-09.01`.

The hosted audit contained 1,308 Auth users before cleanup. No profile lacked
both its saved name and phone. Two unapproved `codex_prevtests_*@example.com`
accounts had neither user-supplied name metadata nor a phone; their visible
names were only the signup trigger's email-local-part fallback. Both had zero
enrollments, tests, course data, push tokens, coupon references, and Storage
objects and were deleted from Auth. `medbank.study2026@gmail.com` also lacked
source name/phone metadata but has a saved profile name and was deliberately
preserved.

**Files touched:** `supabase.config.js`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`. Hosted data: two stale test Auth users removed.

### 2026-08-07 — Google sign-in latency on both sides of the redirect
Two unrelated stalls, both fixed. Read this before re-adding an `await` to
either path.

1. **Pre-redirect: don't bootstrap auth to build a URL.**
   `getSupabaseAuthClientForInteractiveSignIn()` used to `await
   initSupabaseAuth()` — the full callback/getSession/profile/warmup bootstrap,
   whose `getSession()` alone has a 30 s timeout — before the button could
   redirect. It now uses `getSupabaseAuthClient() ||
   getOrCreateSupabaseBrowserClient()` and fires `initSupabaseAuth()` in the
   background. `startGoogleOAuthSignIn` / `startAppleOAuthSignIn` also no longer
   go through `queueSupabaseAuthRequest`: with `skipBrowserRedirect: true`,
   `signInWithOAuth` only constructs the provider URL and writes the PKCE
   verifier, so queuing it behind an in-flight `getSession`/refresh bought
   nothing. **Do not re-queue these two calls** — the queue exists for calls
   that share the storage lock *and* hit the network.
2. **Post-redirect: the student warmup is blocking only when it must be.**
   New `runStudentPostAuthRefresh(user, reason)` (next to
   `schedulePostAuthDataWarmup`) replaces four direct
   `await ensureFreshStudentDataAfterAuth(...)` sites: the OAuth/session
   bootstrap in `initSupabaseAuthNow`, the `onAuthStateChange` SIGNED_IN path,
   the session-recovery path, and the password-login handler. It awaits the
   warmup only when `hasUsableLocalStudentContent(user)` is false; otherwise it
   defers to `schedulePostAuthDataWarmup()`. The 2026-06-22 invariant is
   preserved — a student with no cached catalog still waits, so create-test and
   analytics cannot render a false "no questions" empty state — and
   `getStudentContentReadiness()` already reports the background pass through
   `isPostAuthDataWarmupActive()` / `state.studentDataRefreshing`.
3. **Verified** in the preview: client acquisition 0 ms and authorize-URL
   construction 1 ms against the real hosted project (previously gated on the
   bootstrap), and both branches of `runStudentPostAuthRefresh` exercised with
   stubs — no cached content takes the blocking path, cached content returns
   immediately and schedules the background warmup. `node --check` and
   `npm run lint` clean.
4. **Static cache bust:** `2026-08-07.03`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-07 — Sign-in survives a stalled first connection (ISP routing fault)
**Read this before debugging "Supabase is temporarily unavailable" again — the
cause was not Supabase and not the app.**

`fzjzjzdamehxbgikiskt.supabase.co` resolves to two Cloudflare anycast
addresses. From the affected network `104.18.38.10` is **blackholed** (100%
packet loss; traceroute dies at `195.22.198.195`, an international transit hop)
while `172.64.149.246` answers in ~66 ms. Measured with
`curl --resolve`: the dead address never connects, the live one completes the
whole request in 0.39 s. A client that picks the dead address stalls ~22-30 s in
TCP connect before falling back — longer than `AUTH_SIGNIN_TIMEOUT_MS`.
Meanwhile the project reported `ACTIVE_HEALTHY` on db/auth/rest/realtime/storage
and a warmed browser fetch returned in 234 ms.

Diagnosis recipe (do this first next time, it takes a minute):
```
curl -o /dev/null -w "dns:%{time_namelookup} connect:%{time_connect} firstbyte:%{time_starttransfer}\n" https://<ref>.supabase.co/auth/v1/health
```
A near-zero `dns` with a huge `connect` means routing, not database load. Then
`dig +short <host>` and test each address with `curl --resolve host:443:<ip>`.

1. **`preconnect` + `dns-prefetch` for the Supabase origin** in `index.html`
   move the handshake to first paint. Keep them next to the font preconnects;
   they are load-bearing on bad networks, not a micro-optimization.
2. **`runSupabaseSignInWithTransientRetry()`** retries sign-in once, but *only*
   for transient errors. It returns immediately on
   `isInvalidLoginCredentialsMessage` / `isSupabaseAccessRevokedMessage` — do
   not widen this, or a wrong password will consume the auth rate limit.
3. **Deliberately not done:** the app cannot choose which IP the browser
   connects to, so there is no further client-side fix. The durable fix is a
   Supabase **custom domain** (different address set).
4. **Static cache bust:** `2026-08-07.02`.

**Also observed while diagnosing (not fixed, worth a low-traffic cleanup):**
severe table bloat with `last_autovacuum` null on the hot tables —
`test_history_entries` is 322 MB for 861 rows, `app_state` 472 MB for 2,985
rows, `user_course_enrollments` 13 MB for 4,773 rows. Planner stats are stale
(`n_live_tup` reads 0 for several populated tables). `VACUUM (ANALYZE)` is the
safe first step; `VACUUM FULL` takes an ACCESS EXCLUSIVE lock and must wait for
a low-traffic window. See `docs/supabase-disk-io-runbook.md`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-07 — Transient Supabase reads no longer lock students out
After a bulk content upload, many students were stuck on **"Course Access Needs
Attention"** and the profile page showed a permanent **"Loading..."** MedBank ID.
Neither was a real access or database problem.

1. **Invariant added: an unread enrollment index is not an empty one.** A
   timed-out/5xx `user_course_enrollments` read used to become a blocking
   `enrollment_query_failed`, which was then *persisted* onto the local user.
   `hydrateRelationalProfiles()` was worse — it swallowed the error and left
   `enrollmentDiagnosticsMap = {}`, which downstream read as a genuine
   `missing_enrollment`, so a load spike fabricated "you have no enrollment" for
   whole cohorts. Both paths now call `resolveStudentEnrollmentAccessIssue()`.
   **Do not reintroduce a code path that derives an access issue from enrollment
   data without first checking whether the read succeeded.**
2. **`ENROLLMENT_DERIVED_ACCESS_ISSUE_CODES` are non-sticky.**
   `getStudentAccessIssue()` drops a stored `enrollment_query_failed` /
   `missing_enrollment` / `inactive_enrollment` when the student currently
   resolves to courses (`getAvailableCoursesForUser`, which falls back to
   curriculum courses from the approved year/semester). Stuck students therefore
   self-heal on the next page load with no migration and no admin force refresh.
   `not_approved` / `profile_incomplete` / `missing_enrollment_term` are admin
   decisions and remain authoritative. RLS is still the real gate — the frontend
   issue is a UX affordance only, so letting a student through on a failed read
   cannot leak content.
3. **Failed reads preserve cached enrollment.** Both paths fall back to the
   existing `enrolledCourses` instead of writing `[]`, and
   `shouldBackfillStudentEnrollment` is gated on `!enrollmentFetchFailed` so a
   failed read cannot trigger a bogus enrollment "repair" write.
4. **`runSupabaseQueryWithTransientRetry()`** (next to
   `runSupabaseQueryWithAbortTimeout`) retries transient errors with exponential
   backoff; the enrollment batch read uses it.
5. **`upsertLocalUserFromAuth()` now persists `publicUserId`.** It accepted the
   override but never wrote it into `nextUser`, so every auth event/token
   refresh rebuilt the local user without it. `profiles.public_user_id` is NOT
   NULL server-side, so a missing local value always means a lost merge, never
   missing data.
6. **Static cache bust:** `2026-08-07.01`.

**Verified** by lifting the real `resolveStudentEnrollmentAccessIssue` /
`getStudentAccessIssue` out of `main.js` into a Node harness (11 cases: failed
read with and without fallback, fabricated `missing_enrollment`, genuine empty
and inactive enrollment, stale-issue clearing, admin decisions preserved), and by
driving the running app: a demo student given the exact stuck
`enrollment_query_failed` state now renders dashboard/create-test/analytics/
profile normally with the MedBank ID shown, while unapproved and
incomplete-profile students are still routed to their gates.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-06 — Role changes no longer revert after an admin save
Changing a user's role in the admin dashboard could snap back to the previous
role a moment later. The database write was always correct; the revert was
purely a client-side race.

1. **Root cause: `overlayConcurrentAdminUserWrites()` never overlaid `role`.**
   The overlay exists so a profile hydration that started *before* an admin
   action cannot save its stale snapshot over the fresh change. It covered
   name/email/phone, approval, access flags, assigned courses, and year/semester
   -- but not `role`. A hydration landing mid-change therefore restored whatever
   role the server reported when that hydration began.
2. **The admin short-circuit made it worse.** The function returned early and
   unmodified when the fresh local role was `admin`, so promoting a user *to*
   admin was reverted by the same race. Role is now overlaid *before* that
   short-circuit, so both directions survive; the early return still prevents
   student-shaped fields being overlaid onto an admin.
3. **Creator scope is normalized in the overlay.** When the fresh role is
   `creator`, assigned/enrolled courses are cleared and year/semester are nulled,
   matching what the role-change handler writes.
4. **Non-racing hydration is unchanged.** When no admin write landed during the
   hydration window the snapshot still passes through untouched, so ordinary
   server-wins behavior is preserved.
5. **Static cache bust:** `2026-08-06.01`.

**Verified** by driving the real admin UI in local demo mode (student -> creator
and admin -> creator both persist) and by simulating the hydration race directly
against `overlayConcurrentAdminUserWrites()`: a stale `admin` snapshot now
resolves to `creator`, a stale `student` snapshot resolves to `admin`, and the
no-race case still lets the server value win.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-05 — Assign the creator role from the admin dashboard
The `creator` role existed in the database but could not be assigned from the
app. Adding the UI required fixing a latent data-corruption bug first.

1. **Role coercion no longer demotes creators.** 18 sites in `main.js` coerced
   `role` to `"admin" | "student"`, including the profile write-back at
   `syncProfilesToRelational`. A `creator` profile was flattened to `student` on
   hydration and that demotion was then **written back to Supabase** on the next
   admin save. All 18 now use the new `sanitizeUserRole()` helper, which
   preserves `creator` and falls back to `student` for unknown values.
2. **Two coercions are deliberately kept.** `user_presence` and
   `user_activity_sessions` have `check (role in ('student','admin'))`, so a
   creator is reported as a student in that telemetry. Both sites carry a
   comment; do not "fix" them without widening the CHECK constraints first.
3. **Admin Users row: role selector.** The two-way "Make admin / Make student"
   button is now a Student/Creator/Admin `<select>` (`data-action=set-user-role`,
   was `toggle-user-role`). Switching to creator clears MCQ year/semester and
   assigns no curriculum courses; creators are auto-approved because an admin
   provisions them deliberately. The self-edit guard is unchanged.
4. **Add-user form** offers Creator alongside Student and Admin, and
   `admin-create-user` accepts `creator` (it previously normalized any
   non-`admin` role to `student`, silently downgrading the request).
5. **Static cache bust:** `2026-08-05.02`.

**Files touched:** `main.js`, `styles.css`, `index.html`,
`supabase/functions/admin-create-user/index.ts`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-05 — Activation modal redesign, in-site YouTube player, short MedBank IDs
Three changes; no auth/access/RLS behavior touched.

1. **Coupon modal redesign.** `renderCourseCouponModal()` now renders a
   voucher-style dialog (`.course-coupon-card`, `.course-coupon-voucher`,
   `.course-coupon-success`). All wiring ids/actions are unchanged
   (`course-coupon-form`, `course-coupon-code`, `courses-close-coupon`,
   `courses-open-activated-course`); only markup/CSS changed. New CSS is
   appended at the end of `styles.css`, token-based for all three themes.
2. **YouTube lessons use the internal player.** `renderLessonViewer` routes
   YouTube lessons through `renderYouTubeLessonVideoPlayer()`: a
   `youtube-nocookie` embed with `controls=0&enablejsapi=1` driven by the
   shared `.lesson-video-controls` bar over the widget postMessage protocol
   (`wireYouTubeLessonVideoPlayerControls`, `youtubeLessonRuntime`). No
   external YouTube script is loaded (CSP unchanged; `frame-src` already
   allowed the embed host). A click shield + paused/ended overlays hide
   YouTube chrome; the watermark layer now renders over YouTube lessons.
   Controls markup is shared via `renderLessonVideoControlsMarkup()`. Note:
   re-renders reload the iframe (iframes cannot be detached without reload);
   the runtime restores position/rate/mute on the iframe `load` event.
   Fullscreen prefers native element fullscreen, falling back to the existing
   pseudo-fullscreen helpers.
3. **Short MedBank IDs + admin ID search fix.** `matchesAdminUserSearchTerm`
   now returns an exact match on `publicUserId` before the digits-only query
   falls into the exact-phone path (that path previously swallowed all-digit
   ID searches). Migration `20260805031500_shorten_public_user_ids.sql`
   (rollback in `supabase/rollbacks/`) renumbers `profiles.public_user_id`
   from the 8-digit range to sequential IDs starting at 100 by disabling the
   immutability trigger inside the migration only; the sequence and check
   constraint move to `>= 100`. **Not yet applied to the hosted project** —
   apply before shipping frontend copy that assumes short IDs. Demo accounts
   now use 901/902/903.
4. **Static cache bust:** `2026-08-05.01`.

**Files touched:** `main.js`, `styles.css`, `index.html`,
`supabase/migrations/20260805031500_shorten_public_user_ids.sql`,
`supabase/rollbacks/20260805031500_shorten_public_user_ids.sql`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-08-04 — Video Course public IDs, YouTube lessons, and activation coupons
Video Courses now use centralized full-course/module access. Do not treat the
presence of a `platform_course_enrollments` row as proof that every module is
open: inspect `access_scope` or call `get_my_platform_course_access()`. Existing
rows were backfilled to `full/manual`; full access includes future modules and
always overrides additive `platform_course_module_entitlements`.

Profiles have an immutable `public_user_id` numeric display/admin key; UUIDs
remain canonical. YouTube lessons store only a normalized 11-character
`youtube_video_id` plus the original URL and render through
`youtube-nocookie.com`. Coupons are globally one-time, hash-only, and redeemed
only through `redeem_platform_course_coupon()` using `auth.uid()` plus a row
lock. Plain codes are returned once by the admin generation RPC. Protected
lesson/resource rows now require exact module/full access. Uploaded Video Course
files are signed through `course-video-url`; direct student Storage SELECT was
removed. Flutter contract: `docs/video-courses-mobile-integration.md`. Static
cache bust: `2026-08-04.06`.

**Files touched:** `main.js`, `styles.css`, `bootstrap.js`, `sw.js`,
`video-courses-utils.js`, `package.json`, Video Course migrations/tests/docs,
`supabase/config.toml`, `course-video-url`, `cloudflare-stream-token`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-08-04 — Sign in with Apple enabled
The hosted Apple provider is configured for web and native sign-in. The primary
App ID is `com.medbank`; the web Services ID is `com.medbank.web`; and Supabase
accepts `com.medbank.web,com.medbank` in that order. The Apple callback points
to the hosted Supabase Auth callback, and the website feature flag is now
enabled. The client-secret JWT and `.p8` key remain outside the repository.
Static cache bust: `2026-08-04.02`.

**Files touched:** `supabase.config.js`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-08-03 — Account deletion moved to the legal footer
The full account-deletion block was removed from the public Contact destination.
The standalone `deletion.html` resource is now the single public page for the
request process, deleted/retained data, and retention periods. Every public
marketing route receives a shared footer with Privacy Policy and Account
Deletion links, and the static first-paint fallback mirrors it. Static cache
bust: `2026-08-03.06`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-08-03 — Mobile app campaign header uses the app icon only
The duplicate horizontal MedBank wordmark was removed from the mobile app
campaign header. The square mobile app icon remains beside the coming-soon
status in both the SPA render and static first-paint fallback. Static cache
bust: `2026-08-03.05`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-08-03 — Mobile store availability rows fixed
The MedBank App campaign's three store cards are now full-width compact rows
instead of narrow three-column tiles. Explicit CSS grid placement keeps icon →
store name → device badge order stable, prevents AppGallery from breaking onto
an orphaned final letter, and moves the badge below the name at 420px and
narrower. Static cache bust: `2026-08-03.04`.

**Files touched:** `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-08-03 — Dedicated MedBank App page with real store assets
The public top bar now includes **MedBank App**. It scrolls to
`#landing-mobile-app` while already on the homepage and otherwise opens the
dedicated public `#mobile-app` route. `mobile-app` is part of `KNOWN_ROUTES`,
`PUBLIC_MARKETING_ROUTE_SET`, and `AUTH_ENTRY_ROUTE_SET`; keep those entries in
sync if this page is renamed.

The campaign uses the actual Flutter app icon, wordmark, and six English iPhone
store screenshots copied from the sibling `Medbank-App` project into
`Assets/mobile-app/`. The copies are web-sized and lazy-loaded; do not point the
website at sibling-project paths because GitHub Pages cannot serve them. The
gallery is horizontally scrollable with keyboard focus and scroll snapping.
The static `index.html` first-paint fallback mirrors the SPA markup. Static
cache bust: `2026-08-03.02`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`, `Assets/mobile-app/*`.

### 2026-08-03 — Upcoming mobile apps announced on the homepage
The public homepage now includes a responsive launch panel immediately below
the hero announcing upcoming releases on Google Play, Apple's App Store, and
Huawei AppGallery. Store cards are intentionally non-clickable until real
listing URLs exist. A phone-shaped MedBank study-loop preview provides the
single visual signature, and reduced-motion users do not receive the status-dot
animation. The same announcement appears in the static `index.html` first-paint
fallback. Static cache bust: `2026-08-03.01`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-07-28 — Google indexing migration repaired after Pages URL rename
The earlier repository rename changed the public path from
`/o6u-medbank-app/` to `/Medbank-Website/`, but the old Pages URL returned a
hard 404. A separate compatibility repository now serves instant meta-refresh
redirects from the former home and privacy URLs to their canonical new
locations. Keep that legacy Pages repository live for at least one year; GitHub
Pages cannot provide custom HTTP 301 rules.

The canonical home page now has a descriptive search title/description,
Organization + WebApplication JSON-LD, an explicit sitemap discovery link, and
accurate sitemap modification dates. Its JSON-LD block is covered by the CSP
hash in `index.html`; if the block changes, recompute that hash. Static cache
bust: `2026-07-28.03`.

**Files touched:** `index.html`, `sitemap.xml`, `CHANGELOG.md`, `AGENTS.md`.
External compatibility site: `Youssef256D/o6u-medbank-app`.

### 2026-07-28 — Privacy policy now covers web and mobile releases
The canonical `docs/legal/privacy.md` and public `privacy.html` now disclose
iOS/iPadOS/Android behavior: Supabase account and learning data, Firebase Cloud
Messaging tokens and delivery information, device registration, protected
mobile session storage, local preferences, and notification controls. The
policy states that MedBank has no ads or cross-app tracking and that Sentry is
disabled in the current mobile release.

**Files touched:** `privacy.html`, `docs/legal/privacy.md`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-07-28 — Admin approval/refresh no longer blocked by push retries
The admin `Refreshing...` hang was a frontend queue-coupling problem, not a
normal Supabase free-tier request cap.

1. `flushPendingSyncNow()` no longer drains the device-push notification outbox
   unless explicitly requested. Admin approval/access writes and **Force
   student refresh** therefore finish independently from old notification jobs.
2. Notification delivery is now single-flight and bounded to five jobs per
   pass, with a 25-second per-job timeout and exponential retry backoff. When
   the notification row was saved but no registered device matches its
   audience, the job is complete (the in-app notification remains available)
   rather than being retried indefinitely.
3. Enrollment hydration and admin-presence reads have abort timeouts. Manual
   **Refresh from cloud** has a 90-second outer failsafe that clears
   `state.adminDataRefreshing`, surfaces the timeout, and restores the button.
4. The cloud status pill distinguishes admin reads (`Refreshing cloud
   data...`) from student refresh publication (`Sending student refresh...`).
5. New students no longer inherit old notifications. Hosted migration
   `20260728152618_restrict_notifications_to_post_signup.sql` adds a
   `profiles.created_at <= notifications.created_at` eligibility condition to
   the notification SELECT policy. The SPA repeats the cutoff for relational
   queries and local cached rendering.
6. Deployed `send-push-notification` v8 applies the same profile-creation cutoff
   before loading device tokens, so retrying an old notification cannot push it
   to a newer account. Student-role verification returned zero visible
   pre-signup notifications while preserving valid post-signup notifications.
7. Static cache bust: `2026-07-28.02`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`,
`supabase/functions/send-push-notification/index.ts`, migration and rollback
`20260728152618_restrict_notifications_to_post_signup.sql`.

### 2026-07-24 — Google Play account-deletion web resource
The public deletion pathway is now explicit and crawler-friendly.

1. `#contact` prominently explains how to request deletion, exposes a
   pre-addressed email action, lists deleted/retained data, and discloses the
   20-day previous-test window, normal 30-day completion target, and maximum
   90-day residual-record window unless longer retention is legally required.
2. Standalone `deletion.html` is the preferred Google Play Console deletion URL;
   it works without the SPA runtime and is linked from Contact,
   `privacy.html`, `sitemap.xml`, and the canonical legal docs.
3. Static cache bust: `2026-07-24.02`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `deletion.html`,
`privacy.html`, `sitemap.xml`, `README.md`, `docs/legal/README.md`,
`docs/legal/privacy.md`, `docs/legal/deletion.md`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-24 — Public support email updated
The shared landing/Contact card now displays and links to
`Code.Youssefaayoub@gmail.com`, matching the Flutter app store support address.
Static cache bust: `2026-07-24.01`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-22 — Interactive notification destinations and learning deep links
Admin notifications can deep-link to allowlisted student SPA routes and exact learning context.

1. Admin Notifications has an **Open when clicked** selector for Apps home,
   MCQ Bank dashboard, Create Test, MCQ analytics, Video Courses, and Profile.
2. Migration `20260722104608_add_notification_destinations.sql` adds nullable
   `notifications.target_route` with a database CHECK constraint. Never replace
   this with arbitrary URLs; frontend and Edge Function allowlists are defense
   in depth against unsafe redirects.
3. Top-bar notification items and destination-enabled cards are accessible
   buttons. Opening one marks it read locally, queues relational read sync, and
   navigates through `navigate()`. Legacy rows with no destination remain valid.
4. `send-push-notification` forwards the selected route in the FCM data payload,
   falling back to `/notifications` for legacy rows. Its data payload also
   forwards optional MCQ Subject/topic and Video Course identifiers.
5. Create Test destinations can preselect an MCQ Subject and topic. Video
   Courses destinations can open a selected published course directly while
   the normal MCQ access and Video Course enrollment gates remain authoritative.
6. Migration `20260722110548_add_notification_deep_link_targets.sql` adds the
   constrained deep-link context columns. Static cache bust: `2026-07-22.03`.

**Files touched:** `main.js`, `styles.css`, `index.html`,
`supabase/functions/send-push-notification/index.ts`, migrations `20260722104608`
and `20260722110548`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-07-22 — One-device enforcement rolled back
The one-registered-device feature is **not active**. It was applied briefly and
then disabled because it blocked existing devices.

1. Migration `20260722032411_rollback_one_registered_device.sql` removes
   `user_devices`, the public device RPCs, private helpers, and every added
   restrictive RLS/Storage policy, restoring the previous access functions and
   anonymous `app_state` policies.
2. The static SPA and Cloudflare Stream token function contain no device claim
   or session-device gate. Do not assume `user_devices`, `claim_user_device`, or
   `check_user_device` exists in the hosted schema.
3. Both `20260722025152_enforce_one_registered_device.sql` and its rollback stay
   in the repository because both were applied to the hosted migration ledger.
4. Static cache remains `2026-07-22.01`.

**Files touched:** `main.js`, `index.html`, both device migration files,
`supabase/functions/cloudflare-stream-token/index.ts`, `CHANGELOG.md`,
`AGENTS.md`.

### 2026-07-22 — Firebase device-push delivery for admin notifications
Admin announcements now have a secure server-side push path in addition to the
existing in-app notification rows.

1. **Tokens remain private.** `push_device_tokens` has RLS enabled and no direct
   client grants. The app can register/unregister only its own token through
   authenticated RPC wrappers backed by `private` SECURITY DEFINER functions.
2. **Delivery is admin-only and idempotent.** The
   `send-push-notification` Edge Function independently validates the bearer
   token and admin profile, targets recipient/year/all audiences, sends through
   FCM HTTP v1, and records each token result in
   `push_notification_deliveries` so retries skip successful sends.
3. **Credentials stay server-side.** Never add a Firebase service-account JSON
   to the repo or frontend. Store it only as the Supabase secret
   `FIREBASE_SERVICE_ACCOUNT_JSON`. Firebase client identifiers/API keys are
   injected into the mobile build through `env.json`.
4. **Outbox retries failures.** `createRelationalNotification()` invokes the
   function after saving the row; a zero-device or provider failure is returned
   as unsuccessful so the existing browser outbox retries it.
5. **Static cache bust:** `2026-07-22.01`.

**Files touched:** `main.js`, `index.html`, `supabase/config.toml`,
`supabase/functions/send-push-notification/index.ts`, migrations
`20260722020710` and `20260722021623`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-21 — Post-billing Supabase restoration + renamed-site connection audit
The hosted project was restored after billing suspension and audited end to end.

1. **Auth URL corrected live.** Supabase Auth `site_url` now points to
   `https://youssef256d.github.io/Medbank-Website/`; the redirect allowlist
   includes the new URL, old URL (compatibility), and localhost. Google OAuth
   is enabled and its authorize endpoint accepts the new callback (`302`).
2. **Apple UI feature-gated.** Apple OAuth is disabled in the hosted project.
   `supabase.config.js → appleOAuthEnabled: false` now hides the Apple buttons
   instead of advertising a broken provider. Enable only after configuring the
   Apple provider and credentials in Supabase.
3. **Migration history reconciled.** The four July 6 migrations had been
   applied remotely under timestamps `20260706140112`, `20260706141024`,
   `20260706141100`, and `20260706141320`, while the repo retained older local
   timestamps. The repo now uses the real hosted timestamps and includes the
   five remote July 16 migrations. A dry run then showed only
   `20260721120000_add_mcq_subject_alias_views.sql`; it was applied successfully.
4. **Connection checks passed.** GoTrue health `200`; browser `app_state` reads
   `200`; invalid-password auth reaches `/auth/v1/token` and returns normal
   `400` (not a fetch failure); all seven Edge Functions are ACTIVE; admin
   mutation endpoint rejects unauthenticated requests with `401`; all six core
   tables exist; all four required Storage buckets exist; alias views have
   `security_invoker=true`.
5. **Cloudflare is intentionally dormant.** `cloudflareStreamEnabled` remains
   false, so video courses use Supabase Storage. Cloudflare functions are
   deployed but cannot be enabled until `CLOUDFLARE_STREAM_API_TOKEN` is added.
6. **Static cache bust:** `2026-07-21.04`.

**Files touched:** `supabase.config.js`, `main.js`, `index.html`, hosted Auth
configuration, migration history files, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-21 — "Video Courses" vs "MCQ Subjects" naming split
**Read `docs/NAMING.md` before touching anything course-related.** MedBank has
two unrelated products that were both called "Courses"; that ambiguity was the
single biggest source of agent error in this repo.

1. **Video LMS → "Video Courses".** Student route `courses` → `video-courses`;
   admin page id `course-platform` → `video-courses`
   (`ADMIN_COURSES_PLATFORM_PAGE`). Tables unchanged (`platform_*`).
2. **MCQ curriculum unit → "MCQ Subject".** Admin page id `courses` →
   `mcq-subjects` in `ADMIN_DATA_PAGES`; sidebar label "Course Topics" →
   "MCQ Subjects". The product name stays "MCQ Bank".
3. **The trap, restated:** `public.courses` / `public.course_topics` are the
   **MCQ subjects**, not the video LMS. The 13 `.from("courses")` call sites in
   `main.js` were deliberately left untouched by the rename.
4. **Legacy ids alias forward.** `LEGACY_ROUTE_ALIASES` /
   `LEGACY_ADMIN_PAGE_ALIASES` + `canonicalizeRoute()` /
   `canonicalizeAdminPage()` (defined next to the route sets) map `courses` →
   `video-courses` and `course-platform` → `video-courses`, applied in
   `readRouteFromHash()`, `resolveInitialRoute()`, `resolveInitialAdminPage()`.
5. **DB layer is additive only.** Migration `20260721120000` adds read-only
   `security_invoker` views `mcq_subjects` / `mcq_subject_topics` plus table
   comments. **No table renamed, no RLS policy touched, no FK altered** — a
   table rename would have required dropping/recreating 34 policies on live
   student data, which was explicitly rejected as too risky for a naming fix.
   The `security_invoker = true` setting is load-bearing: without it the views
   would bypass RLS. Rollback in `supabase/rollbacks/`.
6. **Verified** in preview: no console errors, `npm run lint` clean,
   `node --check main.js` passes, nav renders "MCQ Bank / Video Courses",
   admin sidebar renders "MCQ Subjects", and legacy `#courses` resolves rather
   than dead-ending.
7. **Static cache bust bumped.** `index.html` app-version is `2026-07-21.01`.

**Files touched:** `main.js`, `index.html`, `docs/NAMING.md`,
`supabase/migrations/20260721120000_add_mcq_subject_alias_views.sql`,
`supabase/rollbacks/20260721120000_add_mcq_subject_alias_views.sql`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-07-10 — MCQ section nav bar
Navigation/design only; no auth/access/sync/data behavior changed.

1. **`renderMcqSectionTabs(activeRoute)`** (`main.js`, next to
   `renderCoursePlatformTabs`) renders a `.courses-tabs .mcq-tabs` pill row —
   Dashboard / Create Test / Analytics — using `data-nav` so the existing
   body-level nav delegation handles it. Reuses `.courses-tabs` CSS for an exact
   style match (no new styles needed).
2. **Inserted** at the top of `renderDashboard()` (after the Back-to-Apps
   button), `renderCreateTest()`, and `renderAnalytics()` main panels.
3. **Verified** in preview: bar renders on all three MCQ routes, active pill
   moves on click. Completes the earlier "MCQ nav bar" TODO.
4. **Static cache bust bumped.** `index.html` app-version is `2026-07-10.04-local`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-10 — Mobile app polish batch (auth, courses, privacy, demo MCQs)
Mobile/native-focused. No auth/access/sync/data-model behavior changed.

1. **Compact OAuth row.** Login + signup wrap the Google/Apple buttons in
   `.auth-oauth-row`; new CSS makes them side-by-side, icon-only ≤640px (label
   in `.auth-oauth-label`, visually hidden on mobile). `styles.css`, `main.js`.
2. **Mobile Courses default = list.** `state.coursesLayout` initializer returns
   `list` when `matchMedia("(max-width: 640px)")` matches and no saved choice.
3. **Native privacy screen app-wide.** `setCoursePrivacyObscured()` eligibility
   now also true for `isNativeMobileAppShell() && getCurrentUser()`, so the
   `is-course-privacy-obscured` overlay covers all routes when backgrounded.
4. **Floating back button.** `.course-back-btn` mobile block: `position:relative;
   z-index:4; margin-bottom:-40px` so it overlaps the card below.
5. **Demo MCQs.** `DEMO_MCQ_QUESTIONS` (8 published, course
   "Introduction to Body Structure (BOS 101)" = Year 1 Sem 1) seeded in the
   demo-user init path when `isLocalDemoAuthEnabled()` and no local questions.
   Verified: create-test shows 8 usable questions + 4 topics for the demo student.
6. **Still TODO (not in this batch):** YouTube-style lesson layout (full-width
   video on top, then title/description/mark-complete, then course nav) and an
   MCQ section nav bar mirroring the courses tabs for create-test/analytics/MCQ.
7. **Static cache bust bumped.** `index.html` app-version is `2026-07-10.03-local`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-10 — Native app opens on login (no marketing site)
Routing-only change for the Capacitor native shell. Web (GitHub Pages) is
unchanged — it still opens on `landing`. No auth/access/sync/data behavior changed.

1. **New helper `isNativeMobileAppShell()`** (`main.js`, right after
   `AUTH_ENTRY_ROUTE_SET`). Detects the native shell from window/location only
   (no `SUPABASE_CONFIG` dependency, since it runs before that const): true for
   `window.__MEDBANK_MOBILE_APP__`, `window.__SUPABASE_CONFIG.forceMobileAuthRedirect`,
   `Capacitor.isNativePlatform()`/`cordova`/`ReactNativeWebView`, or a
   `capacitor:`/`ionic:`/`file:` protocol.
2. **Initial route.** `resolveInitialRoute()` maps any `PUBLIC_MARKETING_ROUTE_SET`
   route to `login` and defaults to `login` (instead of `landing`) in the native shell.
3. **Runtime guard.** `render()` redirects any marketing route to `login`
   (signed out) or the app (`admin`/`app-launcher`, signed in) when native.
4. **Verified** in preview by toggling `window.__MEDBANK_MOBILE_APP__`: native →
   `/landing` no longer renders `.landing-simple`; web (flag off) still shows it.
5. **Static cache bust bumped.** `index.html` app-version is `2026-07-10.01-local`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-07 — Mobile native app shell (Capacitor prep), phase 1
Design/structure only; no auth, access, sync, or data behavior changed. The app is being wrapped with Capacitor, so the mobile view is moving toward native app-shell patterns. All changes are mobile-scoped (`@media (max-width: 640px)`); tablet/desktop are untouched.

1. **Courses redesign confined to mobile.** The earlier uncommitted Courses changes (flattened `.panel.courses-shell` + `.courses-toolbar-card`, single-row `.courses-stats-row`, and the Cards/List `renderCoursesLayoutToggle`) applied to all sizes; they are now wrapped in mobile media queries. `renderCoursePlatformRowsMarkup` gates the list layout behind `isCoursesMobileViewport()` (`matchMedia("(max-width: 640px)")`) so desktop/tablet always render the card grid; the toggle bar is `display:none` above 640px.
2. **Bottom tab bar.** Added `<nav id="mobile-tabbar">` in `index.html` (after `</main>`), populated by `syncMobileTabBar()` in `main.js` (called at the end of `syncTopbar()` + its restore-pending early return). Student-only, hidden on public/auth routes and `session`/`review`. Tabs: Apps (`data-nav="app-launcher"`), MCQ Bank (`data-action="open-mcq-bank"`, if `isUserMcqAccessEnabled`), Courses (`data-action="courses-home-tab"`), Profile. Uses the existing body-level click delegation (`main.js` ~L16541/16730) — no new listeners.
3. **Safe area + clearance.** `index.html` viewport gained `viewport-fit=cover`. CSS: `.mobile-tabbar` uses `env(safe-area-inset-bottom)`; `body.has-mobile-tabbar .app-shell` reserves bottom padding so the fixed bar never covers content (session route keeps its own padding).
4. **Touch/press.** 44px min-height floor for `.top-nav button`/`.btn`/`.user-menu-trigger` on mobile; tab press-scale + `prefers-reduced-motion` guard. Tab-bar styling is token-based (`--surface`/`--line`/`--brand`/`--muted`) so light/dark/comfort all work.
5. **Single navigation path (mobile).** With the bottom bar as the one primary path, the top `#private-nav` is hidden via `body.has-mobile-tabbar #private-nav { display:none }` (≤640px only). It was pure duplication: app-launcher tabs mirror the bottom bar, Courses section tabs also render in-page via `renderCoursePlatformTabs` → `.courses-tabs` (`main.js` ~L44284/44837), and MCQ Create/Analytics live in the dashboard `.dash-quick-actions` (`main.js` ~L23603). Admins have no bottom bar, so their top nav is untouched. Also: compact app-bar `env(safe-area-inset-top)` padding, `-webkit-overflow-scrolling`/`overscroll-behavior-y: contain`, tap-highlight removal — all mobile-scoped.
6. **Static cache bust bumped.** `index.html` app-version is `2026-07-07.24-local` (drop `-local` before production).

**Files touched:** `index.html`, `main.js`, `styles.css`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Landing first-paint fallback fix
Visual-only startup fix: the static `index.html` `#app` fallback still contained the old "Medical MCQ practice platform." hero, which could flash on refresh/first load before `main.js` replaced it with `renderLanding()`. Replaced the fallback with the current simplified landing hero so the first paint and hydrated render match.

1. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.06-local` (preview/local; drop `-local` before production).

**Files touched:** `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Restore MCQ card green
Visual-only reversal after owner review: restored the light-theme `.exam-question-card` background to the prior soft green-blue (`#c4dde5`) and border (`#b9d3da`) from the older MCQ screen. Selected/correct/wrong answer colors and exam logic were not changed.

1. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.05-local` (preview/local; drop `-local` before production).

**Files touched:** `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Supabase sync overhaul (approval reverts, stale banks, admin speed, DB hardening)
Fixed the reported sync problems: approvals reverting to pending, slow admin dashboard sync, and students stuck on stale question banks. Touches `main.js`, `supabase/functions/admin-set-user-access` (deployed v6), and three new hosted migrations.

1. **Per-user timestamp merge replaces the 30s wall clock.** Admin user writes stamp `user.profileUpdatedAt` (centrally in `save()` when `userSyncScope` is ADMIN + `profileSyncIds`; the approval path stamps the server's `profiles.updated_at` from the update's `select`). `shouldPreferRecentLocalUserData(user, serverUpdatedAtIso)` now compares per-user timestamps (legacy clock only as fallback for unstamped rows); `hydrateRelationalProfiles` persists `profileUpdatedAt = max(local, server)` on merged rows. `overlayConcurrentAdminUserWrites` additionally overlays name/email/phone.
2. **Flush freshness guard.** `flushRelationalWrites` sends `getUsers()` (freshest local snapshot) for the users key instead of the queued snapshot, so a stale queued payload can't re-push old approval/access flags via `syncProfilesToRelational`. `scheduleRelationalWrite` with `force: true` now bypasses and unblocks `blockedStorageKeys`.
3. **Edge Function consistency.** `admin-set-user-access`: one retry w/ backoff on auth ban updates; on approve-flow auth failure the profile `approved` flag is reverted (consistent-deny) and returned in `revertedProfileIds`.
4. **`content_versions` signal (hosted migration `20260706140112`; originally authored locally as `20260706120000`).** One-row-per-scope table; statement triggers on `questions`/`question_choices` bump the `questions` version; SELECT-only RLS for `authenticated`; added to the realtime publication. `refreshStudentDataSnapshot` compares it against local `mcq_question_content_version` (STORAGE_KEYS.questionContentVersion) and forces question hydration when it moved; `ensureContentRealtimeSubscription` also listens to `content_versions` UPDATEs. `REQUIRED_QUESTION_CATALOG_REFRESH_VERSION` remains as legacy backstop. Rollback in `supabase/rollbacks/`.
5. **Admin poll fast path.** `hydrateRelationalProfiles(user, {skipIfUnchanged:true})` (used only by the 30s dashboard poll via `refreshAdminDataSnapshot({skipUnchangedProfiles:true})`) probes newest `profiles.updated_at` + exact count and skips full hydration when unchanged (cursor cleared in `resetRelationalSyncState`). `fetchRowsPaged` fetches pages in parallel waves of 4 after a full first page.
6. **DB hardening (user-confirmed).** Hosted migration `20260706141024` adds 19 FK indexes. Hosted migration `20260706141100` consolidates duplicate permissive policies on questions/question_choices/courses/course_topics/profiles/app_feature_flags/test_block_items (merged `items_write` ALL policy into per-command policies whose predicates are the exact OR of the originals) and initplan-wraps `auth.uid()`/helpers on those + `user_activity_sessions`; verified behavior-preserving by identical row counts under real student and admin JWTs before/after; rollback recreates originals verbatim. Hosted migration `20260706141320` revokes anon/authenticated EXECUTE on internal definer RPCs, anon on `get_admin_question_count_summary`, and pins search_path on `private.course_code_key`/`course_name_key`. These were originally authored locally under `20260706121000`, `20260706122000`, and `20260706123000`; the repo now uses the actual hosted migration timestamps so `supabase db push` stays in sync. Remaining advisor items deliberately deferred: `platform_*` duplicate SELECT policies (low traffic) and the Auth leaked-password-protection dashboard toggle (manual step).
7. **Housekeeping.** Deleted stray uncommitted `database/migrations/20260701_remove_forced_admin_promotion.sql`. Note: the multi-tab refresh-trigger "seen token" race suspected earlier does **not** exist — tokens are marked seen only after a successful refresh.
8. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.04-local` (drop `-local` before production).

**Files touched:** `main.js`, `index.html`, `supabase/functions/admin-set-user-access/index.ts`, `supabase/migrations/20260706{120000,121000,122000,123000}_*.sql`, `supabase/rollbacks/20260706{120000,122000}_*.sql`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Landing contact routing, owner details, GSAP motion, mobile auth trim
Follow-up to the landing rebuild. Content/design + motion only; no auth/access/data behavior changed.

1. **Courses CTA → Contact.** The Courses section button is now `data-nav="contact"` ("Contact us about courses") instead of `signup`, so prospective course owners reach the platform rather than self-registering.
2. **Contact shows owner details, not a form.** `landingContactBodyHtml()` renders a contact card — Youssef Ayoub · MedBank owner, `tel:+201004532728` (displayed `+20 100 453 2728`), and `mailto:youssefayoub2525@gmail.com` — for contact and pricing. `landingContactSectionHtml()` (landing scroll `#landing-contact`) and the standalone `renderContact()` route both use it, so they stay consistent. The old `#support-form` was removed; `wireContact()` no-ops safely when the form is absent. (This is a deliberate public listing of the owner's phone/email at the user's request — not a secret, does not violate the frontend-secrets rule.)
3. **GSAP on the landing.** Extended `setupGsapMarketingPageMotion` (on-load hero/head + card stagger) and `getGsapRouteRevealTargets` (scroll reveals) with the new `.landing-simple` selectors: `.lp-eyebrow`/`.lp-hero-title`/`.lp-hero-lede`/`.lp-hero-actions`/`.lp-hero-note`/`.lp-kicker`/`.lp-product-title`/`.lp-product-lede` (intro) and `.lp-points li`/`.lp-contact-card`/`.lp-product-head` (reveal). Reuses the existing reduced-motion gating and ScrollTrigger batch. Verified: gsap loaded, ScrollTrigger active (6 triggers), `data-gsap-marketing-wired=1`.
4. **Mobile auth trim.** `.auth-public-copy` (the "Welcome back" marketing copy + benefit chips on login/signup) is set to `display:none` inside the existing `@media (max-width: 960px)` block — that's where the auth shell goes single-column, i.e. the stacked "mobile" presentation. Desktop (>960px) still shows it (`display:grid`, verified).
5. **Verified** at 1200px and 375px: Courses CTA resolves to `contact`, tel/mail hrefs correct, no console errors, GSAP active, mobile auth copy hidden / desktop shown.
6. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.03-local` (preview/local; drop `-local` before production).

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Simplified landing + split into MCQ Bank / Courses pages
Reworked the public landing from a loud single-scroll marketing page into a calm, simple site with two dedicated product pages. Content/IA + design only; no auth, access, or data behavior changed.

1. **`renderLanding` rebuilt.** Four sections now: a neutral centered Home hero (`MEDBANK` eyebrow, `Protected courses + a medical MCQ bank.` with a teal `+` signature, one-line lede, Log in / Sign up), an **MCQ Bank** section, a **Courses** section, and a trimmed Contact form. The old two-column `.mb-hero` + `.mcq-specimen`, the six `.feature-showcase-card`s, the four-tier `.pricing-tier` table, and the About timeline were removed from the landing.
2. **Two dedicated product pages.** Added marketing routes `mcqs` (MCQ Bank) and `courses-platform` (Courses) — chosen to avoid colliding with the existing student `courses` route. Each renders both as a scroll section on the landing (`#landing-mcqs`, `#landing-courses-platform`, so the scroll-spy in `wireLanding` keeps working) and as a standalone route via `renderMcqBankPage()` / `renderCoursesPlatformPage()`. Shared markup lives in `landingMcqBankSectionHtml()` / `landingCoursesSectionHtml()`. Both routes were added to `KNOWN_ROUTES` and `PUBLIC_MARKETING_ROUTE_SET`, with `switch(state.route)` cases.
3. **Nav trimmed.** `index.html` `#public-nav` is now Home / MCQ Bank / Courses / Contact. The `features` / `pricing` / `about` routes + `renderFeatures`/`renderPricing`/`renderAbout` are **retained** (still reachable by direct `#features` / `#pricing` / `#about` URL) but unlinked — nothing deleted, so this is reversible. Follow-up option: delete those three functions/routes if the simpler site is confirmed.
4. **CSS scoped.** New styles live under `.landing-simple` in `styles.css` (appended after `#landing-home`), using existing tokens (`--brand`, `--text`, `--muted`, `--line`, `--surface-strong`, `--radius-md`, `--font-display`). The older `.mb-hero` / `.mcq-specimen` / `.feature-showcase` / `.pricing-*` / `.about-*` classes are left in place, now unused by the landing.
5. **Verified** at 1200px and 375px (home, both product sections, contact, nav scroll + scroll-spy, standalone `#mcqs`) with no console errors. `node --check main.js` passed.
6. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.02-local` (preview/local; drop `-local` before production).

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Mobile exam-session visual refresh
Calmed the mobile MCQ exam screen after a visual review flagged it as loud and cramped. Design-only; no exam logic, scoring, sync, or access behavior changed.

1. **Eliminate ("strike") control redesigned.** The per-option eliminate button rendered a bordered box containing a struck-through "S" (`.exam-choice-strike`), top-aligned down the right edge of every option — it read as broken/mysterious. It is now a quiet ghost control: transparent border, `opacity: 0.45` at rest, vertically centered (`align-self: center`), with a subtle hover/focus background and a red active state only when a choice is eliminated. The ambiguous `<span>S</span>` glyph in `main.js` (choice render ~L25592) was replaced with an inline strikethrough SVG.
2. **Question card softened.** `.exam-question-card` changed from a saturated teal fill (`background: #c4dde5; border: #b9d3da`) to a white surface with a hairline border (`rgba(35,52,102,0.1)`) and a subtle shadow, so it no longer competes with the blue selected / green correct / red wrong states. Added faint per-row dividers, rounded padded option rows, and bumped the selected tint (`0.06 → 0.10`) so the chosen option reads as a clear blue pill. The `body.theme-dark`/`body.theme-comfort` `.exam-question-card` overrides (styles.css ~L8561/8583) were left intact.
3. **Quiz-nav cells rounded.** `.exam-nav-item` radius `6px → 9px` for cohesion with the refreshed card.
4. **Verification.** The exam session is behind auth + live Supabase data, so it was verified via a temporary standalone mock rendered against the real `styles.css` at 375px in the preview tooling (mock file removed after). `node --check main.js` passed.
5. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.01-local` (preview/local; drop `-local` before production).

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-05 — CSS custom-property alias fix
Fixed 7 orphan `var()` references in `styles.css`, found via a `/design-sync` re-sync.

1. **Root cause.** Rules used `var(--text)`, `var(--border)`, `var(--brand-dark)`, `var(--accent-strong)`, `var(--shadow-tiny)`, `var(--radius-xs)`, `var(--shadow-medium)` — none of which were ever defined. Only differently-named canonical tokens existed: `--ink`, `--line`, `--brand-strong`, `--accent`, `--shadow-soft`, `--radius-sm`, `--shadow`.
2. **Fix.** Added the 7 as `:root`-level aliases (`--text: var(--ink);`, etc., right after `--data-warn`). Because the canonical tokens are redefined per theme (`body.theme-dark`, `body.theme-comfort`), a single `:root` alias resolves through to the active theme's value automatically — no per-theme duplication needed.
3. **Design-sync config corrected too.** `.design-sync/config.json`'s `runtimeFontPrefixes` still listed the removed "Bricolage Grotesque"; updated to `["Source Sans 3", "Inter"]` to match what `index.html` actually loads. Removed a dead `.design-sync/missing-tokens.css` + `cfg.tokensGlob` from an earlier unfinished attempt at this same fix (that mechanism silently never wired in — `copyTokens` requires `cfg.tokensPkg`, not just `tokensGlob` — and its invented hex values didn't match the real palette anyway).
4. **Static cache bust bumped.** `index.html` app-version is `2026-07-05.01`.

**Files touched:** `styles.css`, `index.html`, `.design-sync/config.json`, `.design-sync/NOTES.md`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-01 — Approval no longer reverts to unapproved
Fixed a race where approving a user (or toggling access) could snap back to "pending" a moment later.

1. **Root cause: stale-snapshot clobber in `hydrateRelationalProfiles()`.** The hydration reads its local-users + server-`profiles` snapshot at function start, then does slow paged fetches. An admin approval landing mid-flight was overwritten when the hydration saved its stale snapshot. The pre-existing `shouldPreferRecentLocalUserData` guard made it worse by locking in the stale `existing.isApproved === false`.
2. **Fix: `overlayConcurrentAdminUserWrites(nextUsers, hydrationStartedAt)`.** Before the hydration's `saveLocalOnly(STORAGE_KEYS.users, ...)`, if `relationalSync.lastUserLocalWriteAt > hydrationStartedAt`, the current (fresh) local `isApproved`/`approvedAt`/`approvedBy`/`mcqAccessEnabled`/`coursesAccessEnabled`/`authAccessKnownActive`/assigned-courses/year/semester are overlaid onto the matching hydrated rows so the admin action wins.
3. **Safe signal.** Only `USER_RELATIONAL_SYNC_SCOPE_ADMIN` writes stamp `lastUserLocalWriteAt` (`shouldStampRecentLocalUserWrite`); the hydration's own `server_backfill` writes do not, so normal hydration is untouched and only genuine concurrent admin mutations trigger the overlay.
4. **Approve action sequence unchanged.** Enrollment sync → DB approval → auth-access sync ordering (required for RLS) is preserved; only the post-hydration reconciliation changed.
5. **Static cache bust bumped.** `index.html` app-version is `2026-07-01.05`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-01 — CSP connect-src sourcemap fix
Silenced repeated `Refused to connect to 'https://cdn.jsdelivr.net/sm/....map'` CSP console errors.

1. **Sourcemap fetches are now allowed.** With DevTools open, the browser fetches sourcemaps for the CDN libraries (Lucide/GSAP/supabase-js) from jsDelivr's `/sm/` service. The CSP `connect-src` only allowed `self` + Supabase, so every fetch was blocked and logged. Added `https://cdn.jsdelivr.net` and `https://unpkg.com` to `connect-src` in `index.html`.
2. **No new origin exposure.** Both hosts are already trusted in `script-src`; this only permits sourcemap/companion fetches from the same script CDNs.
3. **Static cache bust bumped.** `index.html` app-version is `2026-07-01.04`.

**Files touched:** `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-01 — Marketing "Answer Key" redesign
Gave the public landing/features/pricing routes a distinct, subject-true visual identity without changing the static-SPA deploy model. Design-only; no business/auth/access logic touched.

1. **Hero signature is an MCQ specimen.** `renderLanding` now leads with a two-column hero: thesis headline (highlighter-swiped differentiator phrase) + a live-looking clinical MCQ card with A–E options, the correct answer resolved, and a short explanation. This embodies the one thing pure-LMS competitors lack.
2. **Structural motif replaces decoration.** Feature cards use meaningful mono section codes (`MCQ / Video / Blocks / Review / Devices / Admin`) via a new `.feature-code` element instead of the old decorative `01–06` `.feature-card-icon`. Pricing is a 4-tier table (`.pricing-tier-grid`) with tabular figures and a quiet `.pricing-notes` billing bar (replacing the `.pricing-steps-grid` badges). Standalone `renderFeatures`/`renderPricing` mirror the landing sections.
3. **Theme-safe palette + one motion moment.** All new colours come from existing tokens (`--brand`, `--accent`, `--text`, surfaces) so light/dark/comfort stay coherent. New CSS is appended and scoped; a single `prefers-reduced-motion`-gated animation reveals the specimen's check + explanation on load. A `--mb-mono` system monospace stack drives the exam-metadata labels (zero font-load cost).
4. **Static cache bust bumped.** `index.html` app-version is `2026-07-01.03`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-01 — Question sync 409 cleanup
Fixed a Supabase 409 during background `mcq_questions` relational sync.

1. **Server question IDs now win over local cache.** `syncQuestionsToRelationalUnsafe()` always refreshes the Supabase `external_id` → `id` mapping before question upserts instead of trusting cached `question.dbId` values.
2. **Primary keys are not rewritten from stale tabs.** Old browser caches can no longer make a question upsert try to update `questions.id`, which previously failed when `question_choices` already referenced the real row.
3. **Static cache bust bumped.** `index.html` app-version is `2026-07-01.02`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-01 — Production hardening and auth cleanup
Prepared the current update set for production push by documenting the security/auth changes and removing preview-only cache-bust state.

1. **Forced-admin email promotion was removed.** Frontend profile bootstrapping/admin role controls no longer special-case specific email addresses, and the canonical hosted-schema change lives in `supabase/migrations/20260701000000_remove_forced_admin_promotion.sql`.
2. **Edge Function CORS is stricter.** Admin, agent, and Cloudflare Stream functions strip wildcard allowed origins, fall back to the GitHub Pages origin, and return `Vary: Origin` when reflecting an allowed origin.
3. **The static shell has defense-in-depth CSP.** `index.html` now includes a GitHub Pages-compatible meta CSP with matching inline-script hashes, and Apple OAuth buttons reuse the existing Supabase OAuth redirect flow.
4. **Static cache bust bumped for production.** `index.html` app-version is `2026-07-01.01`.

**Files touched:** `main.js`, `styles.css`, `index.html`, `supabase/functions/*`, `supabase/migrations/20260701000000_remove_forced_admin_promotion.sql`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md`, `docs/ARCHITECTURE.md`.

### 2026-06-30 — Landing/pricing repositioning
Repositioned the public marketing copy toward the secure course-platform + MCQ story (inspired by competitor ukkera.com) and applied an active-student pricing model.

1. **Hero + Features now lead with the platform story.** `renderLanding` and `renderFeatures` present secure course-video streaming, cross-device study, and exam-style practice, with the integrated course-aligned MCQ bank called out as the unique differentiator no pure-LMS competitor offers.
2. **Pricing is now pay-per-active-student.** Both the landing `#landing-pricing` section and the standalone `renderPricing` route show tiered per-active-student pricing (15/5/4/3 EGP for 1–100 / 101–500 / 501–1,000 / 1,001+), plus storage (80 EGP/GB one-time, 5%/5GB discount up to 50%, free at 1,000+), wallet billing (1,000 EGP min), and a 14-day money-back note.
3. **Marketing copy only — no billing exists.** Access remains approval-based (`profiles.approved`/access flags). No Stripe/billing/wallet logic was added; these are display-only marketing values.
4. **Static cache bust bumped.** `index.html` app-version was `2026-06-30.05-local` for preview testing before the production hardening update moved it to `2026-07-01.01`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-30 — Admin create authorization validator fix
Fixed a typo in the new `admin-create-user` Edge Function auth gate.

1. **Valid Auth UUIDs now pass.** The function's UUID regex now includes the standard fourth UUID group, matching the older delete/access admin functions.
2. **Create-user no longer false-fails as unauthorized.** Real Supabase admin session user IDs now pass the initial acting-admin validation before the profile role check.
3. **Static cache bust bumped.** `index.html` app-version is `2026-06-30.04` for preview testing.

**Files touched:** `supabase/functions/admin-create-user/index.ts`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-30 — Admin-created user cloud login fix
Fixed admin-created email/password accounts that could be saved locally without a matching Supabase Auth identity.

1. **Admin create now uses Auth.** Added `supabase/functions/admin-create-user`, which verifies the acting admin, creates the Supabase Auth user with a confirmed email/password, writes the matching `profiles` row, and disables access for unapproved students.
2. **The dashboard no longer reports fake success.** `main.js` now calls the create-user Edge Function before adding a Supabase-managed user locally; if cloud creation fails, the user is not added locally.
3. **Local-only duplicates can be repaired.** Re-adding the same email while signed in as a Supabase admin converts a local-only user row into a real Supabase Auth/profile identity instead of blocking on "Email already exists."
4. **Enrollment sync remains after creation.** Once the Auth/profile IDs exist, the existing profile/enrollment relational sync handles assigned courses.
5. **Static cache bust bumped.** `index.html` app-version is `2026-06-30.02` for preview testing.

**Files touched:** `main.js`, `index.html`, `supabase/config.toml`, `supabase/functions/admin-create-user/index.ts`, `README.md`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-30 — Legal page content source and public privacy URL
Added canonical source copy for legal/trust pages and a store-listing Privacy Policy URL without changing the static SPA runtime.

1. **Legal Markdown now exists.** Added `docs/legal/privacy.md`, `terms.md`, `support.md`, and `deletion.md` with front matter for the sync/generation layer.
2. **Privacy is publicly hosted.** Added standalone `privacy.html` and listed it in `sitemap.xml`; store forms can use `https://youssef256d.github.io/o6u-medbank-app/privacy.html`.
3. **Copy matches MedBank architecture.** The pages mention the static GitHub Pages frontend, hosted Supabase source of truth, optional Google sign-in, Cloudflare Stream course-video path, admin/audit workflows, and 20-day previous-test retention.
4. **No SPA route wiring yet.** App routing, service worker precache, and generated legal pages were intentionally left untouched so the sync layer can wire these sources separately.

**Files touched:** `privacy.html`, `sitemap.xml`, `docs/legal/README.md`, `docs/legal/privacy.md`, `docs/legal/terms.md`, `docs/legal/support.md`, `docs/legal/deletion.md`, `README.md`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Previous tests 20-day retention
Added automatic cleanup for previous-test history.

1. **Hosted history is pruned.** Added `delete_old_test_history_entries(20)` and a Supabase Cron job that runs daily at 02:17 UTC, deleting `test_history_entries` older than 20 days.
2. **Stale writes are blocked.** Added a `test_history_entries` trigger that skips inserts/updates older than the 20-day window, so old open tabs cannot reinsert deleted history.
3. **Backups are pruned too.** The helper also removes old completed previous-test sessions from `mcq_sessions` app-state payloads so old deleted history cannot rehydrate later.
4. **Frontend matches retention.** Local session cache, relational hydration, session backup, and session-history sync all enforce the same 20-day window.
5. **Students are warned.** The Previous Tests panel now says previous tests are kept for 20 days and older history is automatically deleted.
6. **Static cache bust bumped.** `index.html` app-version is `2026-06-29.09-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `supabase/migrations/20260629192817_retain_previous_tests_20_days.sql`, `supabase/migrations/20260629193447_enforce_previous_test_retention_on_write.sql`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Cloud status pending-count cleanup
Fixed a misleading dashboard cloud-status loop where session safety backups could appear as user-visible unsynced changes.

1. **Session backup still syncs.** The `mcq_sessions` app-state backup remains queued/flushed for recovery, but it is hidden from the user-facing pending-change count.
2. **Dirty session state is not double-counted.** When relational session history is already queued, `sessionSyncRuntime.dirty` no longer adds a second pending item to the status pill.
3. **Already-synced test history is not re-queued.** Completed sessions with Supabase `dbId`s are skipped when building the relational history payload; Aside confirmed the stuck live tab had 69 already-synced `mcq_sessions` pending.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-29.08-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Student question catalog cache refresh
Fixed stale browser question banks after the full hosted question repair.

1. **Cloud signal sent.** Updated the global `mcq_student_refresh_trigger` payload in hosted Supabase with `mcq_questions`, `mcq_course_topics`, and `mcq_curriculum` so open student tabs force a content refresh.
2. **Local stale banks are bypassed.** Added `mcq_question_catalog_refresh_version`; students who have not seen the `2026-06-29-full-question-repair-v2` catalog force a relational question refresh before trusting old cached counts.
3. **Full course blocks are allowed.** Removed the old 500-question Create Test cap so the count can show and generate all 572 Gynecology questions.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-29.07-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Full question usability repair and fade cleanup
Finished the hosted question-bank repair and fixed a stuck route-fade state.

1. **All questions are usable.** Added/applied a Supabase migration that repaired draft shell rows from the preserved `g:mcq_questions` backup, restored missing backup-backed Neurology rows, and published archived rows that already had valid answer data.
2. **No MCQ content was invented.** The repair only used backup payloads with at least two choices and at least one correct answer.
3. **Live database verified clean.** Hosted Supabase now reports 3,024 total questions, 3,024 published questions, 3,024 published usable questions, and 0 non-published or missing-answer rows. Gynecology is 572/572 usable.
4. **Interrupted fades recover.** `cleanupGsapPageMotion()` now clears route animation handles/classes and inline opacity/blur/transform props so refresh rerenders cannot leave the dashboard washed out.
5. **Static cache bust bumped.** `index.html` app-version is `2026-06-29.05-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `supabase/migrations/20260628234242_repair_all_question_usability.sql`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Student refresh button reliability
Tightened student manual refresh wiring without changing the underlying Supabase sync model.

1. **Student refresh buttons are centralized.** `wireStudentRefreshButtons()` now owns the shared loading state and call to `refreshStudentAnalyticsNow()`.
2. **Create-test recovery buttons work.** Loading/error panels shown from create-test now bind their `Get Updates` button instead of rendering a dead control while content hydration recovers.
3. **Question-choice indexes support count checks.** The admin question-count migration now adds safe indexes on `question_choices(question_id)` and correct choices so the database summary and choice hydration use indexed lookups.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-29.04-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `supabase/migrations/20260629003000_add_admin_question_count_summary.sql`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Admin/student Supabase sync count reliability
Improved data-sync correctness and speed for dashboard question counts without changing the static SPA deployment model.

1. **Admin question counts are database-backed.** Added `get_admin_question_count_summary()` so admin dashboard totals/course rows are computed in Supabase instead of from whichever question rows the browser has hydrated.
2. **Admin refresh stays lightweight.** Dashboard/user refresh now fetches users, courses/topics, notifications, site flags, and the count summary, while full question-row hydration remains scoped to Questions/Bulk Import or explicit heavy refresh paths.
3. **Question data quality is visible.** Admin dashboard now separates total, published, student-usable, published-but-blocked, draft, and archived counts by course.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-29.03-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `supabase/migrations/20260629003000_add_admin_question_count_summary.sql`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Gynecology topic alias filter fix
Fixed a create-test zero-question state caused by stale cached Gynecology topic
aliases after the hosted Supabase topic merge.

1. **Topic aliases now canonicalize in filters.** `Gynecological endocrinology`
   matches `Gynecologic Endocrinology`, and `Female genital infection` matches
   `Female Genital Infections`.
2. **Create-test topic options dedupe by lookup key.** The topic picker now
   prefers topic names present on published usable questions when a configured
   stale alias and a live question topic share the same canonical key.
3. **Static cache bust bumped.** `index.html` app-version is
   `2026-06-29.02-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — Faster student Supabase sync
Reduced how long student routes wait on Supabase after login/page load without
weakening the existing profile, enrollment, or question-bank checks.

1. **Student refresh is split by priority.** The automatic login/page-load
   refresh now waits for the critical relational pass (courses/topics,
   profile/enrollment, and questions), then queues notifications, helper
   app-state keys, and session-history hydration in the background.
2. **Critical reads run in parallel.** Courses/topics, profile/enrollment, and
   question catalog hydration now start together because Supabase RLS enforces
   the access checks server-side.
3. **Question catalog hydration uses larger pages.** The question page size is
   now 1000 rows, matching the catalog RPC cap and reducing round trips for
   larger banks.
4. **Manual/full refresh remains thorough.** Explicit refresh paths still await
   the non-critical hydration work so admin/user flows that expect a full sync
   keep their behavior.
5. **Static cache bust bumped.** `index.html` app-version is
   `2026-06-29.01-local` for preview testing.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-29 — MCQ question visibility data repair
Fixed a hosted Supabase data issue where some admin-visible MCQ rows could not
appear in student-generated tests because they were published without usable
answer choices or correct-answer flags.

1. **Invalid duplicate rows were removed.** Published question rows with missing
   usable answer data were deleted only when a usable same-stem question already
   existed in the same course and the invalid row had no test-block references.
2. **Remaining invalid rows were drafted.** Published rows without enough
   non-empty answer choices or without any correct choice were moved back to
   `draft` instead of being filled with placeholder answers.
3. **Gynecology topics were combined.** Duplicate/synonymous Gynecology topic
   labels were merged into one active topic per concept for Basic Gynecology,
   General Gynecology, Female Genital Infections, and Gynecologic Endocrinology.
4. **All-course verification passed.** Live SQL checks confirmed zero published
   questions across all courses with unusable choice/correct-answer data and
   zero case/spacing duplicate topic-name groups after applying the migration.

**Files touched:** `supabase/migrations/20260628212914_repair_mcq_question_visibility_and_gyne_topics.sql`,
`CHANGELOG.md`, `AGENTS.md`.

### 2026-06-28 — Student dashboard icon refresh
Improved the student dashboard stat/action icons using a static-SPA-safe icon library.

1. **Lucide loads through bootstrap.** `bootstrap.js` now loads Lucide from jsDelivr with unpkg fallback before `main.js`, without introducing a bundler dependency.
2. **Dashboard icons use Lucide.** `studentSvgIcon()` maps student stats/actions to Lucide icons (`target`, `timer-reset`, `list-checks`, `database-zap`, etc.) and still returns inline SVG fallbacks if Lucide is unavailable.
3. **Static cache bust bumped.** `index.html` app-version is `2026-06-28.12-local` for preview testing.

**Files touched:** `bootstrap.js`, `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-28 — Public hero scale cleanup
Adjusted public page hero sizing and the landing CTA area after visual review.

1. **Outer hero titles are smaller.** Marketing hero headings now use a lower desktop/mobile clamp so public headers do not dominate the viewport.
2. **Landing CTA is no longer boxed.** The login/create-account controls remain in place, but the surrounding landing auth card border, background, blur, padding, and shadow were removed.
3. **Static cache bust bumped.** `index.html` app-version is `2026-06-28.10-local` for preview testing.

**Files touched:** `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-28 — Public-only full-frame shell
Changed the outer marketing layout so public pages use the full browser frame while logged-in app pages keep the centered card shell.

1. **Full-frame is route-scoped.** `body.is-public-marketing-route` now controls the edge-to-edge `.app-shell` and applies only to `landing`, `features`, `pricing`, `about`, and `contact`.
2. **Private pages keep cards.** The default `.app-shell` is back to the centered `1200px` card layout, with the existing wider admin/session exceptions preserved.
3. **Scroll reveal is public-only.** GSAP item reveal/ScrollTrigger targets now exclude auth and logged-in routes, so inner app cards do not animate into view while scrolling.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-28.08-local` for preview testing.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-28 — Home and auth page simplification
Simplified the public landing screen and made authentication routes more prominent after visual review.

1. **Landing is calmer.** The home hero now uses a shorter headline, centered copy, compact proof chips, and a focused login/create-account card instead of the busier simulated MCQ preview.
2. **Auth routes have dedicated layouts.** Login, signup, Google onboarding completion, and forgot-password routes now use `auth-public-*` shell/card/form classes with stronger primary actions and clearer explanatory copy.
3. **Responsive and motion coverage was updated.** New auth/landing elements stack cleanly on mobile and participate in the existing GSAP route reveal target system.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-28.06-local` for preview testing.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-28 — Public page visual polish
Expanded the public marketing polish beyond About/Features while preserving the static GitHub Pages SPA model.

1. **About now has visual relief.** Added three static SVG illustrations under `Assets/branding/` for the study workspace, review flow, and analytics/progress story; these are local assets with no runtime API dependency.
2. **Landing, Pricing, and Contact were redesigned.** Landing now has a simulated MCQ/review preview and proof cards; Pricing uses plan/process cards; Contact uses support-routing cards, a signal card, form, and FAQ tiles.
3. **GSAP marketing motion was broadened.** The existing marketing-page motion now covers the new visual/card systems while preserving `prefers-reduced-motion` gating.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-28.05-local`; the new SVGs are included in `sw.js` precache.

**Files touched:** `main.js`, `styles.css`, `index.html`, `sw.js`, `CHANGELOG.md`, `AGENTS.md`, `Assets/branding/about-*.svg`.

### 2026-06-28 — Public About and Features refresh
Expanded the public marketing routes while preserving the static GitHub Pages SPA model.

1. **Features is now a polished marketing page.** The route uses a large hero, proof chips, and premium feature cards covering focused block creation, exam rhythm, review, analytics, and admin workflows.
2. **About now tells the MedBank story.** Added stronger positioning copy, an "Our start" vertical timeline with milestone/date labels, and principle cards for the product direction.
3. **GSAP page motion was extended.** Marketing pages now animate hero text, feature cards, and the About timeline rail/nodes through existing GSAP runtime hooks, with reduced-motion gating intact.
4. **Local cache bust bumped.** `index.html` app-version is `2026-06-28.04-local` for preview testing.

**Files touched:** `main.js`, `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-28 — MedBank identity refresh
Renamed the public-facing product identity from the previous university-branded name to MedBank while preserving the static GitHub Pages deployment model.

1. **Visible identity is now MedBank.** Page title, meta descriptions, nav brand, landing hero, public route copy, admin/report labels, manifest name, docs, and package metadata now use MedBank naming.
2. **Brand assets were refreshed.** Added `Assets/branding/medbank-logo.png` and `.svg`, updated landing/social/precache references, and regenerated the hero brand asset without university-specific text.
3. **Deployment path remains unchanged.** Canonical URLs still point to `/o6u-medbank-app/` until the GitHub repository/pages path is renamed.
4. **Local cache bust bumped.** `index.html` app-version is `2026-06-28.03-local` for preview testing.

**Files touched:** `index.html`, `main.js`, `bootstrap.js`, `sw.js`, `manifest.webmanifest`, `package.json`, `package-lock.json`, `README.md`, `CHANGELOG.md`, `AGENTS.md`, `styles.css`, SQL/docs snapshots, and `Assets/branding/*`.

### 2026-06-28 — Typography refresh
Replaced the playful heading font with a cleaner, more premium medical-study
font pairing.

1. **Headings now use Geist.** The app loads Geist 400/500/600/700 from Google
   Fonts and routes `--font-heading`, `--font-display`, and admin display text
   through it.
2. **MCQ reading stays on Inter.** Body text, stems, options, explanations,
   buttons, and admin UI continue using Inter for high readability.
3. **Font weights are explicit.** Both Geist and Inter now load 400/500/600/700
   to avoid browser-synthesized semi-bold/bold text across dashboards and exam
   surfaces.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-28.01`.

**Files touched:** `index.html`, `styles.css`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-27 — Student content loading speed
Reduced how often approved students are held on the "Checking Your Course Bank"
loading panel while Supabase content sync is still running.

1. **The dashboard can render during sync.** The student dashboard no longer
   blocks on the full question-bank refresh after access checks pass; its
   question-bank stat shows a small syncing indicator until questions arrive.
2. **Usable cached question banks can render immediately.** Create-test and
   analytics readiness now checks whether the current student already has
   assigned courses and usable published questions locally before showing a
   blocking loading panel.
3. **First-load safety stays intact.** Students with no usable local content
   still wait for the first Supabase refresh instead of seeing a false empty
   state in create-test/analytics, and real query errors still surface when
   there is no local fallback.
4. **Background sync is preserved.** The refresh continues to run and the
   existing sync status/button show that updates are in progress.
5. **Static cache bust bumped.** `index.html` app-version is `2026-06-27.03`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-27 — Custom font system
Replaced the older Manrope/Sora CSS import with a static-SPA-friendly Google
Fonts setup in `index.html` and centralized font variables in `styles.css`.

1. **Fonts load from the document head.** The app now preconnects to Google
   Fonts and requests only Bricolage Grotesque 500/700 and Inter 400/500 with
   `display=swap`; no CSS `@import` is used.
2. **Typography is routed through variables.** `--font-heading` and
   `--font-body` drive the app, with the older UI/display/admin variables kept
   as aliases so existing selectors remain maintainable.
3. **Reading surfaces stay body-focused.** MCQ stems, answer options,
   explanations, and rationales explicitly use Inter even when an option is
   implemented as a button.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-27.02`.

**Files touched:** `index.html`, `styles.css`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-27 — GSAP animation runtime
Installed the official GSAP agent skills into `.agents/skills/` and wired GSAP
into the static SPA without changing the deploy model.

1. **GSAP loads through the existing bootstrap path.** `bootstrap.js` now loads
   GSAP 3.13 and ScrollTrigger from public CDNs in the background, registers
   ScrollTrigger when present, and leaves the CSS motion fallback active if the
   CDN is unavailable.
2. **Route and card motion now use GSAP when available.** `main.js` adds
   GSAP-powered route intro timelines, card hover movement, and ScrollTrigger
   reveal hooks for offscreen cards. Admin, exam session, and review surfaces
   stay conservative.
3. **Accessibility fallback is preserved.** `prefers-reduced-motion` skips GSAP
   motion, and the existing CSS route animation remains the fallback.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-27.01`.

**Files touched:** `bootstrap.js`, `main.js`, `styles.css`, `index.html`,
`CHANGELOG.md`, `AGENTS.md`, `skills-lock.json`, `.agents/skills/*`.

### 2026-06-22 — Admin user create refresh fix
Fixed the admin Users dashboard race where a newly added/edited local user could
briefly appear, then lose admin-entered fields after the next Supabase profile
refresh.

1. **Recent admin user data is protected during relational hydration.**
   `hydrateRelationalProfiles()` now actually applies the existing
   `shouldPreferRecentLocalUserData()` decision when resolving name, role,
   phone, approval/access flags, year/semester, and assigned courses. This keeps
   freshly entered admin form data from being overwritten by stale or incomplete
   profile rows while Supabase catches up.
2. **False student access issues are avoided during the same short window.**
   Missing-enrollment diagnostics are delayed while recent local enrollment data
   is intentionally preferred.
3. **Safe merge diagnostics were added.** The debug log reports only profile
   id/email/role and which field groups were protected; it does not log
   passwords, tokens, question data, or secrets.
4. **Static cache bust bumped.** `index.html` app-version is `2026-06-22.03`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-22 — Mobile responsiveness polish
Scoped CSS-only mobile refinements. No business logic, Supabase, auth,
enrollment, course, question, video, or desktop layout behavior was changed.

1. **MCQ answer controls are easier to tap on phones.** The existing mobile
   exam media query now gives radio controls, answer text, and submit actions
   larger touch targets while preserving the desktop exam layout.
2. **Admin side navigation has a mobile scroll affordance.** The admin sidebar
   horizontal tab rail now fades at the right edge on phones, making it clearer
   that additional admin sections can be swiped into view.
3. **Static cache bust bumped.** `index.html` app-version is `2026-06-22.02`
   so clients fetch the updated mobile stylesheet.
4. **Browser checks performed.** Verified public auth, student launcher/MCQ
   dashboard, Courses dashboard, lesson placeholder, MCQ session/review,
   student profile, and admin dashboard/users at phone widths with Playwright.

**Files touched:** `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-22 — Student content access reliability
Fixed stale/early empty states for approved enrolled students.

1. **Auth/content warmup now waits for first student content refresh.** The
   post-auth path awaits the existing boot refresh that loads profile,
   enrollment, courses/topics, and questions before dashboard/create-test can
   claim content is empty.
2. **Question hydration has explicit read state.** `main.js` now tracks
   student question-read status as `idle`, `loading`, `success`, or `error`.
   Dashboard, create-test, and analytics use this to distinguish loading,
   access issues, true zero questions, and query/database errors.
3. **Safe diagnostics added.** Access-decision logs include route, status, and
   row counts only. They do not log question stems, answers, tokens, or secrets.
4. **Courses platform admin enrollment changes now signal students.** Admin
   approve/enroll/remove flows queue the existing student refresh signal with
   `platform_*` keys, and students reload Courses platform data when those keys
   arrive.
5. **Static cache bust bumped.** `index.html` app-version is `2026-06-22.01`.

**Files touched:** `main.js`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-06-18 — Safety & tooling pass (no behavior change to live site)
Performed a multi-part hardening/cleanup pass. **The live site was not affected:
no served file changed behaviorally.** All changes are reversible.

1. **innerHTML / XSS escaping audit (VERIFIED CLEAN — no patches needed).**
   Enumerated all 60 `.innerHTML` assignments and every `${...}` interpolation
   in HTML/attribute/style context. Findings:
   - `escapeHtml()` (main.js ~L40314) is used 525×; discipline is strong.
   - The one field that appeared unescaped — `choice.id` at the session/review
     render sites (e.g. L23624–23635, L24863–24865) — is provably safe: every
     code path into rendering passes through `normalizeQuestionChoiceEntries` →
     `normalizeQuestionChoiceLabel`, which whitelists the label to exactly
     `["A","B","C","D","E"]`. Any other value is discarded. So `choice.id` can
     never carry markup.
   - All `href=`/`src=`/`style=`/`data-action=` interpolations resolve to static
     literals, numerics, or already-escaped values.
   - **No edits to `main.js` were required.** No fabricated patches were added.

2. **esbuild + ESLint tooling scaffolded (deploy NOT flipped).** Added
   `package.json`, `build/esbuild.config.js`, `eslint.config.cjs`. The committed
   `main.js` stays the served source of truth; `dist/` is gitignored.

3. **CI extended.** `.github/workflows/validate-changes.yml` now runs
   `npm run lint` and `npm run build` in addition to the existing `node --check`
   + file-existence checks. Live deploy model unchanged.

4. **`/api` Node admin layer deprecated in place.** Added `@deprecated` headers
   to `api/*.js` pointing to the canonical Edge Functions. Files retained for
   the optional Vercel/Netlify hosting path. README updated with a
   "Canonical admin endpoints" note.

5. **Schema snapshots marked non-authoritative.** Added banner comments to root
   `schema.sql` and `database/schema.sql` clarifying they are historical
   snapshots and that `supabase/migrations/` is canonical. No SQL content
   changed.

6. **Cross-tool docs added.** Created this `AGENTS.md` and `CHANGELOG.md`.

**Files touched:** `AGENTS.md`, `CHANGELOG.md`, `README.md`, `package.json`,
`build/esbuild.config.js`, `eslint.config.cjs`, `.gitignore`,
`.github/workflows/validate-changes.yml`, `api/_supabase.js`,
`api/admin-delete-user.js`, `api/admin-set-user-access.js`,
`api/admin-set-user-password.js`, `schema.sql`, `database/schema.sql`.
**Files NOT touched (behaviorally):** `index.html`, `main.js`, `bootstrap.js`,
`supabase.config.js`, `sw.js`, `styles.css`, all migrations, all Edge Functions.
