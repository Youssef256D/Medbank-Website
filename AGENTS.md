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
