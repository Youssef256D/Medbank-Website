# MedBank — Architecture

> Onboarding map for AI/human contributors. Authoritative rules live in
> [`/AGENTS.md`](../AGENTS.md); this file adds the feature inventory, data flow,
> security posture, and mismatch/risk analysis that AGENTS.md does not cover.
> Where the two disagree, AGENTS.md wins on hard rules.

Last mapped: 2026-06-30.

## 1. Architecture summary

MedBank is a **static single-page app served as-is from GitHub Pages** with
**hosted Supabase** as the single source of truth. There is no build step in the
deploy path — the committed `index.html`, `main.js`, `bootstrap.js`,
`styles.css`, `supabase.config.js`, and `sw.js` are what ship.

- **Pattern:** one giant flat-scope SPA. `main.js` (~47k lines, not a module/IIFE)
  holds a single mutable `state` object and a central `render()` router that
  switches on `state.route` → `renderXxx()` + `wireXxx()`. ~1,066 top-level
  function declarations.
- **Backend:** Supabase Postgres + Auth + RLS + Edge Functions (Deno/TS). The
  browser holds **only the anon/publishable key**; every permission is a Postgres
  RLS policy. Privileged actions go through Edge Functions that hold the
  service-role key server-side.
- **Loading:** `bootstrap.js` (IIFE) loads supabase-js, GSAP, and Lucide from
  CDNs (with fallbacks), handles the OAuth callback + native deep link, registers
  `sw.js`, then injects `main.js` as a classic `<script>`.
- **Stack:** vanilla JS (no framework at runtime — `framer-motion` is a stray
  dep, GSAP is the actual animation runtime loaded via CDN), CSS (~15k lines,
  light/dark/comfort themes), Supabase JS SDK, esbuild + ESLint as **optional**
  tooling only.

## 2. Directory → responsibility map

| Path | Responsibility |
|------|----------------|
| `index.html` | App shell, head/SEO/meta, theme bootstrap, font + GSAP/Supabase preconnect, `app-version` cache-bust string. Injects `bootstrap.js`. |
| `bootstrap.js` | CDN loader + OAuth callback + deep link + SW registration. Loads `main.js`. |
| `main.js` | **The entire SPA.** `state` (~L287), `render()` router (~L19023), all route render/wire fns, sync engine, escaping. |
| `styles.css` | All styling; theme tokens; `--font-heading` (Geist) / `--font-body` (Inter). |
| `supabase.config.js` | `window.__SUPABASE_CONFIG`: hosted URL, anon key, feature flags (`cloudflareStreamEnabled`, `serverApiBaseUrl`). **No secrets.** |
| `sw.js` | Service worker: precache app shell, versioned cache, offline fallback. |
| `supabase/migrations/` | **Canonical schema source of truth** (52 timestamped `.sql` migrations). Apply to hosted project only. |
| `supabase/functions/` | Edge Functions (canonical privileged path): `admin-delete-user`, `admin-set-user-access`, `admin-set-user-password`, `cloudflare-stream-token`, `cloudflare-stream-tus-upload`. |
| `supabase/optional_migrations/`, `rollbacks/` | Selective perf indexes / reverse SQL. |
| `api/` | **DEPRECATED** Node serverless mirrors of the admin Edge Functions. Unused in the GitHub Pages deploy (`serverApiBaseUrl` is empty). Do not extend. |
| `database/` | Historical/reference SQL snapshots. `schema.sql` here is **stale** — not authoritative. |
| `docs/` | Runbooks + this file. |
| `Assets/` | Branding images / SVGs. |
| `build/`, `eslint.config.cjs` | Optional minify/lint tooling, **not in deploy path**. `dist/` is gitignored. |
| `.github/workflows/` | `validate-changes.yml` (lint/build/syntax on push+PR), `deploy-pages.yml` (Pages deploy on push to `main`). |
| `ds-bundle/`, `.ds-sync/` | Design-sync tooling (peripheral; not part of the runtime). |

## 3. Feature inventory

### Working / actively maintained
- **MCQ test flow** — create-test → session → review → analytics, fully relational + RLS.
- **Auth** — email + Google OAuth via Supabase Auth; admin-gated approval flow.
- **Question bank** — ~3,024 published/usable questions (per CHANGELOG 2026-06-29 repair).
- **Student dashboard & analytics** — topic accuracy, weak areas, retry queues.
- **Notifications** — in-app, read tracking, realtime.
- **Offline/cache sync** — `app_state` backup + localStorage fallback + retry queue.
- **Previous-test 20-day retention** — Supabase cron + write guard + frontend filter.
- **Admin portal** — users, courses, questions, bulk import, site-access, activity/logs.

- **Course Platform (LMS)** — live. 9 hosted tables (`platform_courses`,
  `platform_course_modules`, `platform_course_lessons`,
  `platform_course_resources`, `platform_course_enrollments`,
  `platform_lesson_progress`, `platform_course_announcements`,
  `platform_course_enrollment_requests`, `platform_course_suggestions`) with 1
  active published course. Schema is in the in-repo migrations (hosted ledger
  matches all 52). *(Verified against hosted DB 2026-06-30.)*
- **Hermes AI admin assistant** — **removed 2026-10-19** (owner decision).
  Last used 2026-06-11. The page, the `admin-agent-tool` Edge Function and
  the `admin_agent*` tables are gone
  (`20261019200000_drop_hermes_admin_agent`).

### Parked (deployed but disabled)
- **Cloudflare Stream video** — Edge Functions deployed and active, but
  `cloudflareStreamEnabled: false` ([supabase.config.js:32](../supabase.config.js))
  pending billing. App falls back to Supabase Storage videos. Re-enable when ready.

### Deprecated (retained, not used)
- `api/*.js` Node admin endpoints — superseded by Edge Functions.

## 4. Data flow

### Auth / access gating
1. Signup/login via Supabase Auth (`startGoogleOAuthSignIn` ~L21484 for Google; email otherwise).
2. `bootstrapRelationalProfileFromAuth` (~L4124) creates/hydrates a `profiles` row; `refreshLocalUserFromRelationalProfile` (~L4226) syncs into `state`.
3. **Role:** `profiles.role` enum (`student`/`admin`). At signup `approved = (role === 'admin')` — students default `approved=false`.
4. **Access gating is approval-based, NOT plan/payment-based.** Gates: `profiles.approved`, `mcq_access_enabled`, `courses_access_enabled`. Frontend checks (`isUserAccessApproved` etc.) surface error states (`not_approved`, `profile_incomplete`, `missing_enrollment_term`); the real enforcement is RLS + the `admin-set-user-access` Edge Function (admin-only).

### Student taking a test (relational path)
`create-test` form → insert `test_blocks` → populate `test_block_items` (block_id, position, question_id) → answers write to `test_responses` (selected labels, flagged, submitted) → completion writes `test_history_entries` → `getStudentAnalyticsSnapshot` (~L23158) reads history grouped by course/topic.

### Sync model (two paths)
- **Primary: relational tables** (`profiles`, `courses`, `course_topics`, `questions`, `question_choices`, `test_*`, `notifications`, …). RLS enforces `auth.uid()` ownership; admins see all.
- **Secondary/legacy: `app_state`** key-value table for non-relational settings/queues + offline replay only. Namespaced keys: `g:<key>` (global) and `u:<auth.uid>:<key>` (user-scoped). Do not move heavy relational data back into `app_state`.

## 5. Schema / API mismatches

- **Hosted DB is in sync.** `supabase migration list --linked` confirms all 52
  in-repo migrations match the remote ledger through `20260629193447`
  (verified 2026-06-30). No drift. The platform-course tables that an earlier
  scan couldn't locate **do** exist and are created by in-repo migrations.
- **`user_course_enrollments`:** referenced with conditional `IF EXISTS` guards in migrations — may be partly legacy/optional. Verify it's the live enrollment table vs. the platform-course enrollment tables (`platform_course_enrollments`).
- **Stale snapshots:** root `schema.sql` and `database/schema.sql` are historical (~21 tables, pre-Feb-2026) and banner-marked. Migrations are canonical.
- **Migration count:** 52 files in `supabase/migrations/` (the source of truth); `database/migrations/` holds older superseded copies.
- No enum mismatches spotted (`user_role`, `question_status`, `block_mode`, `block_source` match usage).

## 6. Security posture

**Overall: solid.** No secrets in frontend, RLS throughout, escaping disciplined.

- ✅ `supabase.config.js` carries only the publishable/anon key — no service-role key, no Stripe/DB/private tokens in any committed frontend file.
- ✅ Service-role key confined to Edge Functions (`supabase/functions/*`) and the deprecated `api/*`.
- ✅ RLS enabled on all tables; policies key off `auth.uid()` / `is_admin_user()`; questions exposed to students only when `status='published'`.
- ✅ Edge Functions verify bearer JWT and re-check `profiles.role === 'admin'` before mutating.
- ✅ `escapeHtml()` (~L42284) used pervasively; the only apparently-unescaped field (`choice.id`) is whitelisted to `A`–`E` by `normalizeQuestionChoiceLabel` (AGENTS.md §1.5).
- ⚠️ Minor: video/Stream protection is inert while `cloudflareStreamEnabled=false` (Supabase-bucket fallback with watermark only).

## 7. Priority-ranked fixes / follow-ups

1. **Remove the stray `framer-motion` dependency** in `package.json` — GSAP (CDN) is the real animation runtime; this dep is unused and misleading.
2. **Drop the `-local` suffix from `app-version` for production deploys** — code treats the string as opaque so it works, but `…-local` is documented as preview-only, so shipping it is misleading. Convention: `YYYY-MM-DD.NN-local` for preview, `YYYY-MM-DD.NN` for production.
3. **Re-enable Cloudflare Stream when billing is available** — Edge Functions are deployed; just flip `cloudflareStreamEnabled` and complete integration testing.
4. **Clarify `user_course_enrollments` vs. `platform_course_enrollments`** — the conditional `IF EXISTS` guards suggest ambiguity about which is the live enrollment path.

*(The earlier "platform_courses schema gap" and Hermes/Stream "unknown status"
items are resolved — see §3 and §5; verified against hosted DB 2026-06-30.)*

## Notes / conventions

- Exact line numbers above are approximate (47k-line file) — trust function names, re-grep before relying on a line.
- **`app-version` cache-bust:** bump it in `index.html` on any served-file change. Convention: `YYYY-MM-DD.NN-local` for preview/local testing, `YYYY-MM-DD.NN` for production (drop `-local` when shipping).
- Hosted DB ↔ repo migrations confirmed in sync (52 migrations, verified 2026-06-30); platform-course, Hermes, and Cloudflare-Stream statuses all confirmed — see §3, §5, §7.
