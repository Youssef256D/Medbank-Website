# AGENTS.md — MedBank

This file is the shared instruction guide for any AI coding tool working on this
repo (Codex, Antigravity, Zcode, Claude, Cursor, Windsurf, etc.). It states the
project's hard rules, the codebase layout, and a running log of refactors so the
next agent does not accidentally undo prior work or get confused by tooling.

> Read this file before editing. When you finish a change that other tools should
> know about, add an entry at the top of **`docs/refactor-log.md`** and/or **CHANGELOG.md**.

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
   current code is clean (see `docs/refactor-log.md`, 2026-06-18). The one field that looks
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
main.js                 THE SPA — single flat module scope (NOT an
                        IIFE, NOT ES modules). Shared `state` object (`const state =`),
                        central `render()` router (`function render()`) that switches on
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
- `escapeHtml(value)` is the HTML-escaping helper (search `function escapeHtml`). Use it
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

## 7. Refactor log

The full log (every change since 2026-06-18, most recent first) lives in
**[`docs/refactor-log.md`](docs/refactor-log.md)**. It is not loaded
automatically. **Before editing an area, search it** for the function, table,
route, or file you are touching; add your own entry at the top when you finish.

### Load-bearing traps (details in the log)

- **Never write `profiles.mcq_access_enabled` with an upsert.** The BEFORE
  INSERT eligibility trigger fires on upserts and writes `false` into the real
  row. Admin fields go through `update().eq("id")` (2026-10-02).
- **`profiles.auto_approval_blocked_at` is what keeps suspensions sticky.** No
  approval path may ignore it; `private.student_phone_is_valid()` must stay in
  step with `validateAndNormalizePhoneNumber()` (2026-09-10).
- **Realtime retry counts live in `realtimeChannelRetryCounts`, not on the health
  entry** (a rebuild deletes the entry). Keep the `course_topics` subscription;
  `content_versions` does not cover it. Don't publish the coupon tables (2026-09-13).
- **`escapeHtml(0)` returns `""`.** Format numbers before escaping; do not change
  the helper (525+ call sites rely on it), and keep test stubs identical (2026-09-10).
- **An unread enrollment index is not an empty one.** Never derive an access issue
  from a failed read (2026-08-07).
- **Don't re-queue `signInWithOAuth` behind `queueSupabaseAuthRequest`**, and only
  retry sign-in on transient errors, never on bad credentials (2026-08-07).
- **Role handling:** use `sanitizeUserRole()` (keeps `creator`); presence/activity
  tables deliberately coerce to student/admin (2026-08-05).
- **Admin dialogs render in `adminGlobalOverlay`**, never inside the blurred shell;
  only one `admin-help-toggle` listener (2026-09-30).
- **Every new admin page goes in `ADMIN_NAV_GROUPS` and `ADMIN_PAGE_AREAS` /
  `ADMIN_SUPER_ONLY_PAGES`; every new admin-written table needs an
  `_area_guard_` policy** (2026-09-29, 2026-09-30).
- **Tests slice `main.js` by function name** (`renderAdminSidebarNav`,
  `matchesAdminUserFilters`) — renaming or moving those silently breaks tests.
- **Never deploy `send-push-notification` from this repo** (deployed copy is newer,
  Flutter repo); `dispatch-notification-pushes` has no source here.
- **`index.html` first-paint fallback mirrors SPA markup** (landing, store cards,
  dark-mode guard) — edit both; recompute CSP hashes after inline-script edits,
  masking HTML comments first (2026-09-10).
- **`logout()` does not clear `STORAGE_KEYS.users`**; signup and
  `upsertLocalUserFromAuth` are guarded against stale rows instead (2026-09-10).
