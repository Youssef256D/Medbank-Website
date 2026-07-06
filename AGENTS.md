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
- **Public:** `landing`, `features`, `pricing`, `about`, `contact`
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

### 2026-07-06 — Restore MCQ card green
Visual-only reversal after owner review: restored the light-theme `.exam-question-card` background to the prior soft green-blue (`#c4dde5`) and border (`#b9d3da`) from the older MCQ screen. Selected/correct/wrong answer colors and exam logic were not changed.

1. **Static cache bust bumped.** `index.html` app-version is `2026-07-06.05-local` (preview/local; drop `-local` before production).

**Files touched:** `styles.css`, `index.html`, `CHANGELOG.md`, `AGENTS.md`.

### 2026-07-06 — Supabase sync overhaul (approval reverts, stale banks, admin speed, DB hardening)
Fixed the reported sync problems: approvals reverting to pending, slow admin dashboard sync, and students stuck on stale question banks. Touches `main.js`, `supabase/functions/admin-set-user-access` (deployed v6), and three new hosted migrations.

1. **Per-user timestamp merge replaces the 30s wall clock.** Admin user writes stamp `user.profileUpdatedAt` (centrally in `save()` when `userSyncScope` is ADMIN + `profileSyncIds`; the approval path stamps the server's `profiles.updated_at` from the update's `select`). `shouldPreferRecentLocalUserData(user, serverUpdatedAtIso)` now compares per-user timestamps (legacy clock only as fallback for unstamped rows); `hydrateRelationalProfiles` persists `profileUpdatedAt = max(local, server)` on merged rows. `overlayConcurrentAdminUserWrites` additionally overlays name/email/phone.
2. **Flush freshness guard.** `flushRelationalWrites` sends `getUsers()` (freshest local snapshot) for the users key instead of the queued snapshot, so a stale queued payload can't re-push old approval/access flags via `syncProfilesToRelational`. `scheduleRelationalWrite` with `force: true` now bypasses and unblocks `blockedStorageKeys`.
3. **Edge Function consistency.** `admin-set-user-access`: one retry w/ backoff on auth ban updates; on approve-flow auth failure the profile `approved` flag is reverted (consistent-deny) and returned in `revertedProfileIds`.
4. **`content_versions` signal (migration `20260706120000`).** One-row-per-scope table; statement triggers on `questions`/`question_choices` bump the `questions` version; SELECT-only RLS for `authenticated`; added to the realtime publication. `refreshStudentDataSnapshot` compares it against local `mcq_question_content_version` (STORAGE_KEYS.questionContentVersion) and forces question hydration when it moved; `ensureContentRealtimeSubscription` also listens to `content_versions` UPDATEs. `REQUIRED_QUESTION_CATALOG_REFRESH_VERSION` remains as legacy backstop. Rollback in `supabase/rollbacks/`.
5. **Admin poll fast path.** `hydrateRelationalProfiles(user, {skipIfUnchanged:true})` (used only by the 30s dashboard poll via `refreshAdminDataSnapshot({skipUnchangedProfiles:true})`) probes newest `profiles.updated_at` + exact count and skips full hydration when unchanged (cursor cleared in `resetRelationalSyncState`). `fetchRowsPaged` fetches pages in parallel waves of 4 after a full first page.
6. **DB hardening (user-confirmed).** Migration `20260706121000` adds 19 FK indexes. Migration `20260706122000` consolidates duplicate permissive policies on questions/question_choices/courses/course_topics/profiles/app_feature_flags/test_block_items (merged `items_write` ALL policy into per-command policies whose predicates are the exact OR of the originals) and initplan-wraps `auth.uid()`/helpers on those + `user_activity_sessions`; verified behavior-preserving by identical row counts under real student and admin JWTs before/after; rollback recreates originals verbatim. Migration `20260706123000` revokes anon/authenticated EXECUTE on internal definer RPCs, anon on `get_admin_question_count_summary`, and pins search_path on `private.course_code_key`/`course_name_key`. Remaining advisor items deliberately deferred: `platform_*` duplicate SELECT policies (low traffic) and the Auth leaked-password-protection dashboard toggle (manual step).
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
