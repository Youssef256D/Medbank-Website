# MedBank

MedBank is a hosted browser app for medical students. The website is static on GitHub Pages, and the live hosted Supabase project is the single source of truth for auth, courses, questions, progress, enrollments, and admin data.

## Live App

Open the deployed site:

- `https://youssef256d.github.io/Medbank-Website/`

The app does not need a local Supabase instance, local database, or your laptop to stay running. Once GitHub Pages and the hosted Supabase project are available, students and admins can use the app from the web.

## Included MVP flows

- Public pages: Home, Features, Pricing, About, Contact + support form
- Auth: Sign up, Login, Forgot password via hosted Supabase Auth
- Create a test: choose assigned course + topic, set count, mode (`timed`/`tutor`), source (`all`/`unused`/`incorrect`/`flagged`), and randomization
- Attempt interface: select answers, flag, strike-through, notes, navigator, autosave, pause/resume timer
- Review: score summary, per-question explanation, add to incorrect queue
- Analytics: overall performance + topic breakdown + weak areas
- Profile: update account/email/password and view incorrect queue size
- Admin portal: assign courses to accounts, create/edit/delete/publish questions, and bulk import by course/topic

## Legal content

Canonical legal-page copy lives in `/Users/youssefayoub/Documents/Apps/MCQs Website/docs/legal/`:

- `privacy.md` — Privacy Policy
- `terms.md` — Terms of Service
- `support.md` — Support Policy
- `deletion.md` — Data Deletion Instructions

The public Privacy Policy URL for Apple App Store Connect and Google Play
Console is:

- `https://youssef256d.github.io/Medbank-Website/privacy.html`

The public account-deletion URL for Google Play Console is:

- `https://youssef256d.github.io/Medbank-Website/deletion.html`

These files are source copy for generated/public legal pages. Keep them in sync
when privacy, retention, support, account deletion, or platform behavior changes.

## Data/storage

Hosted Supabase is the database for the project. Browser storage is only used for session state, route memory, theme preference, and offline/cache safety; it is not the source of truth.

Supabase is wired through:

- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase.config.js`
- hosted project URL: `https://fzjzjzdamehxbgikiskt.supabase.co`
- browser-safe publishable key in `supabase.config.js`
- SQL migrations in `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/migrations`

Notes:

- The frontend uses only the hosted Supabase URL + publishable/anon key.
- Do not put `SUPABASE_SERVICE_ROLE_KEY` in frontend files.
- Supabase Auth is used for sign up/login/reset email.
- Primary sync path: relational tables (`profiles`, `courses`, `course_topics`, `questions`, `test_blocks`, etc.).
- Legacy `app_state` sync path is now limited to non-relational settings/queues only (to avoid duplicate heavy writes and improve responsiveness).
- Sync keys now support scale-safe namespacing:
  - global keys: `g:<storage_key>`
  - user-scoped keys: `u:<auth.uid>:<storage_key>`

## Supabase connection method for this project

This repo now follows an online-only Supabase connection model:

- Browser frontend (`index.html` + `bootstrap.js` + `main.js`):
  - use Supabase Data APIs through `supabase-js`
  - configured by `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase.config.js`
  - required values: hosted Supabase URL and publishable/anon key
  - do not use Postgres connection strings in the browser
- Server-side admin endpoints (`/api/*.js` and `supabase/functions/*`):
  - current implementation uses Supabase Auth/Admin HTTP APIs with `SUPABASE_SERVICE_ROLE_KEY`
  - no direct Postgres socket connection is opened by the current code
- Schema changes are applied to the remote Supabase project through migrations; do not start or depend on local Supabase.

## Supabase Auth setup checklist

In Supabase Dashboard:

1. Authentication -> Providers:
   - Email: enable Email provider.
   - Google: enable Google provider and set authorized redirect/client settings in Supabase.
2. Authentication -> URL Configuration:
   - Site URL: your deployed URL
   - Redirect URLs: add your deployed URL and the mobile deep link `medbank://auth/callback`
3. Enable leaked-password protection (recommended for production).
4. (Optional) Disable "Confirm email" during testing if you want instant login after sign-up.

## Supabase dashboard tasks still required

You still need to confirm these values in the Supabase project UI:

1. Project dashboard -> `Connect`
   - confirm the project URL
   - confirm the browser-safe publishable/anon key
2. Authentication -> `URL Configuration`
   - set `Site URL` to your deployed frontend URL
   - add all valid redirect URLs used by this app
3. Authentication -> `Providers`
   - enable Email
   - enable Google only if you intend to keep Google sign-in active
4. Database migrations
   - apply migrations to the hosted Supabase project only
   - do not use local Supabase as part of the runtime or release flow
5. Storage
   - create the `question-images` bucket if you want image upload to work
6. Edge Functions or hosting UI
   - if you deploy the canonical admin Edge Functions, set:
     - `SUPABASE_SERVICE_ROLE_KEY`
     - `ALLOWED_ORIGIN`
   - if you host your own `/api` backend instead, set the same server env vars there

Recommended connection selection:

- Use the hosted `Project URL` + publishable/anon key for this website frontend.
- Use the hosted Supabase Dashboard/CLI remote connection for migrations.
- Do not run local Supabase for production or student/admin usage.

## Publish to web

This project is static (`index.html` + `main.js` + `styles.css`), so GitHub Pages works.

### Release workflow

1. Push to `main`.
2. The `Validate Changes` GitHub Action runs automatically.
3. GitHub Pages deploys the static app from the repository.
4. The deployed app talks directly to the hosted Supabase project.

Quick GitHub Pages steps:

1. Push the project to a GitHub repository.
2. Repo Settings -> Pages:
   - Source: Deploy from branch
   - Branch: `main` and `/ (root)`
3. Wait for Pages to publish, then open your site URL.
4. Put that URL into Supabase Authentication URL Configuration (Site URL + Redirect URLs).

Alternative hosts (often easier for env management): Netlify, Vercel, Cloudflare Pages.

## Server Functions (phase 1)

This repo now includes a backend function for sensitive admin actions:

- `/Users/youssefayoub/Documents/Apps/MCQs Website/api/admin-delete-user.js`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/api/admin-set-user-access.js`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/api/admin-set-user-password.js`
- shared helpers: `/Users/youssefayoub/Documents/Apps/MCQs Website/api/_supabase.js`

What it does:

- Verifies the caller's Supabase access token.
- Checks the caller role from `profiles` (`admin` only).
- Deletes target users via Supabase Admin API using `SUPABASE_SERVICE_ROLE_KEY` (server-side only).
- Updates target user access/approval via Supabase Admin API and `profiles` (server-side only).
- Updates target user passwords via Supabase Admin API using `SUPABASE_SERVICE_ROLE_KEY` (server-side only).

Required environment variables (server):

- `SUPABASE_URL` (or `NEXT_PUBLIC_SUPABASE_URL` / `PUBLIC_SUPABASE_URL`)
- `SUPABASE_SERVICE_ROLE_KEY` (or `SUPABASE_SECRET_KEY`)
- `ALLOWED_ORIGIN` (optional, defaults to `*`)

Frontend config:

- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase.config.js` now supports `serverApiBaseUrl`.
- Default value is empty (`""`) for GitHub Pages/static deploys.
- For same-origin deploys with functions (for example, Vercel static + functions together), set it to `"/api"`.
- If frontend and API are on different domains, set a full URL (for example, `https://your-api.vercel.app/api`).

For GitHub Pages-only deploys, `serverApiBaseUrl` can stay empty and the app will use Supabase Edge Functions fallback.

### Canonical admin endpoints

The production GitHub Pages deploy uses Supabase Edge Functions as the canonical
admin API:

- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-delete-user/index.ts`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-create-user/index.ts`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-set-user-access/index.ts`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-set-user-password/index.ts`

The `/api/*.js` files are deprecated in place and retained only for an optional
Vercel/Netlify-style hosting path where `serverApiBaseUrl` is set. Do not extend
the `/api` copies for production behavior; extend the Edge Functions instead.

### Supabase Edge Function fallback (no separate `/api` backend)

You can deploy these Edge Functions and keep `serverApiBaseUrl` empty:

- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-delete-user/index.ts`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-create-user/index.ts`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-set-user-access/index.ts`
- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/functions/admin-set-user-password/index.ts`

Deploy to the hosted Supabase project:

```bash
supabase functions deploy admin-delete-user
supabase functions deploy admin-create-user
supabase functions deploy admin-set-user-access
supabase functions deploy admin-set-user-password
```

Optional CORS allow-list (defaults to `*` if not set):

```bash
supabase secrets set ALLOWED_ORIGIN=https://your-site.example.com
```

How it works with this app:

- The frontend first tries `serverApiBaseUrl/admin-create-user`, `serverApiBaseUrl/admin-delete-user`, `serverApiBaseUrl/admin-set-user-access`, and `serverApiBaseUrl/admin-set-user-password` if configured.
- If not available, it automatically falls back to:
  - `https://<project-ref>.supabase.co/functions/v1/admin-create-user`
  - `https://<project-ref>.supabase.co/functions/v1/admin-delete-user`
  - `https://<project-ref>.supabase.co/functions/v1/admin-set-user-access`
  - `https://<project-ref>.supabase.co/functions/v1/admin-set-user-password`

## Hermes admin assistant

The Admin Dashboard includes a `Hermes Assistant` page for one permanent external administrator connection. Set up Hermes once, then rotate its token or disable the connection when needed; the dashboard does not create additional assistant identities.

Security model:

- The browser displays a new agent token only once; Supabase stores only its SHA-256 hash.
- Agent calls use the `admin-agent-tool` Edge Function, which holds the server-only service credential.
- Every authorized tool attempt is saved in `admin_agent_action_log`.
- Assistants without full administrator tools request approval before publishing announcements through `admin_agent_approval_requests`.
- An admin can disable Hermes or rotate its token immediately.
- The Edge Function can also validate Hermes from `HERMES_AGENT_TOKEN_HASH` + `HERMES_AGENT_ID` secrets. This keeps Hermes responsive when the `admin_agents` lookup is slow; the readable token is still shown only once and is never stored.

Scoped tools:

- `get_dashboard_summary` requires `read_dashboard`.
- `create_announcement_draft` requires `draft_announcements` and always creates an unpublished draft.
- `request_publish_announcement` requires `request_content_publish` and queues an approval in the dashboard.

Full administrator tools:

- `get_tool_catalog`, `list_admin_records`, and `manage_admin_record` cover the dashboard's allowlisted relational data areas: MCQ courses/topics/questions, course-platform content, enrollments, announcements, notifications, and feature availability. Hermes can view its connection records for visibility but cannot create or edit assistant identities through the API.
- `bulk_import_mcqs` imports up to 100 structured MCQ rows at a time, creates missing course topics when requested, and replaces question choices when a stable `externalId` is imported again. Imports are drafts by default.
- `create_user`, `update_user_profile`, `set_user_access`, `set_user_password`, and `delete_user` cover user administration. `delete_user` requires an explicit `confirm: "DELETE_USER"` input.
- `read_shared_setting` and `write_shared_setting` control the dashboard's shared site-maintenance, refresh, auto-approval, course-link, feedback, invite, and log settings.
- `resolve_platform_enrollment_request` applies course access decisions.
- These tools require `full_admin`, are server-side only, and every attempted action is written to `admin_agent_action_log`.

Deploy the function after applying the latest migration:

```bash
supabase functions deploy admin-agent-tool
```

If rotating Hermes outside the dashboard, update both the database row and these function secrets:

```bash
supabase secrets set HERMES_AGENT_TOKEN_HASH=<sha256-token-hash> HERMES_AGENT_ID=<admin-agent-id> HERMES_AGENT_NAME="Hermes Admin Assistant"
supabase functions deploy admin-agent-tool --no-verify-jwt
```

Request format for an agent integration or future MCP adapter:

```bash
curl -X POST "https://<project-ref>.supabase.co/functions/v1/admin-agent-tool" \
  -H "X-Agent-Token: mba_<token-shown-in-dashboard>" \
  -H "Content-Type: application/json" \
  -d '{"action":"get_dashboard_summary","input":{}}'
```

Bulk MCQ import request format:

```json
{
  "action": "bulk_import_mcqs",
  "input": {
    "defaultCourse": "Exact course name from mcq_courses",
    "defaultTopic": "Topic name",
    "importAsDraft": true,
    "createMissingTopics": true,
    "records": [
      {
        "externalId": "hermes-source-file-row-001",
        "stem": "Question text",
        "choiceA": "Option A",
        "choiceB": "Option B",
        "choiceC": "Option C",
        "choiceD": "Option D",
        "correct": "A",
        "explanation": "Explanation",
        "difficulty": "Medium"
      }
    ]
  }
}
```

Use a stable unique `externalId` for each question so repeated automation updates that question instead of creating a duplicate. To publish deliberately, set `importAsDraft` to `false` and provide `"status": "published"` on the records being published.

Do not place an agent token, `SUPABASE_SERVICE_ROLE_KEY`, or an LLM provider key in `main.js`, `supabase.config.js`, or any deployed frontend file.

## Protected long course videos with Cloudflare Stream

Long course videos should use Cloudflare Stream, not Supabase Storage. Supabase still stores the lesson row, course access, progress, and the `cloudflare-stream://<video_uid>` reference.

For a temporary free setup, keep `cloudflareStreamEnabled: false` in `supabase.config.js`. The app will upload lesson videos to the private Supabase Storage bucket and show the student-name watermark in the lesson player. This is useful for quick testing, but it is not as secure or scalable as Cloudflare Stream for 30 minute to 3 hour videos.

Required Supabase Edge Function secrets:

```bash
supabase secrets set CLOUDFLARE_ACCOUNT_ID=your_cloudflare_account_id
supabase secrets set CLOUDFLARE_STREAM_API_TOKEN=your_stream_api_token
supabase secrets set CLOUDFLARE_STREAM_CUSTOMER_CODE=your_customer_code
supabase secrets set ALLOWED_ORIGIN=https://youssef256d.github.io
```

The Cloudflare token should have Stream permissions. The customer code is the value in Stream player URLs like `customer-<CODE>.cloudflarestream.com`.

Deploy the video functions:

```bash
supabase functions deploy cloudflare-stream-tus-upload
supabase functions deploy cloudflare-stream-token
```

Protection model:

- Admin uploads go through a TUS resumable upload URL created server-side.
- Uploaded videos require Cloudflare signed URLs.
- Students request a short-lived playback token only after Supabase confirms access.
- The player shows a visible student watermark to discourage screen-recorded leaks.

## Hosted SQL database

The real PostgreSQL schema lives in hosted Supabase. Keep database changes in migrations:

- `/Users/youssefayoub/Documents/Apps/MCQs Website/supabase/migrations`

Apply migrations to the hosted project only:

```bash
supabase db push --dns-resolver https
```

No local Postgres database is required for the website to run.

## Notes

The production data path is hosted Supabase. Local browser storage remains only a cache/UX layer for route memory, theme, and offline-safe pending writes.

## 2,000-user hardening (completed in this repo)

- Frontend sync now isolates high-churn user data (`sessions`, `incorrect queue`, `flashcards`) into user-scoped cloud keys.
- Supabase `app_state` RLS policies were migrated to support global/user-scoped key patterns.
- Duplicate index and RLS policy performance issues were resolved.
- Core relational tables were created in Supabase (`profiles`, `courses`, `course_topics`, `questions`, `question_choices`, `test_blocks`, `test_block_items`, `test_responses`) with indexes and RLS.
- Phase-2 bridge is active: admin users/questions/tests and course/topic changes are persisted directly to relational tables (with local cache as UI state).

Applied Supabase migrations:

- `scale_app_state_keys_and_rls_for_2000_users`
- `optimize_app_state_rls_and_indexes`
- `create_core_relational_tables_for_2000_users`
- `add_external_ids_and_foreign_key_indexes`
