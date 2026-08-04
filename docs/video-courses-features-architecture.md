# Video Courses access, coupons, YouTube, and public IDs

Feature version: `2026-08-04.06`  
Required database migration: `20260804205400` plus correction `20260804211839`

## Audited architecture

- Supabase Auth UUIDs are the canonical identity. `public.profiles.id` is the same UUID and all existing foreign keys continue to use it.
- Video Courses use `platform_courses`, `platform_course_modules`, `platform_course_lessons`, `platform_course_resources`, `platform_course_enrollments`, and `platform_lesson_progress`. The older `courses` and `course_topics` tables belong to MCQ Subjects, not the LMS.
- Existing manual course access is one row per `(user_id, course_id)` in `platform_course_enrollments`. Admins manage courses, modules, lessons, resources, announcements, enrollment, and suggestions from the classic-script SPA in `main.js`.
- The GitHub Pages frontend uses the Supabase anon key. Administrative writes are protected by existing admin RLS checks or authenticated RPC/Edge Functions; service-role credentials remain only in Edge Functions.
- Uploaded course videos use the private `course-videos` bucket. Cloudflare Stream support exists but is feature-disabled. Before this feature, student Storage signing was course-level and lesson rows were broadly visible for suggested courses.

## Chosen architecture

### Identity

`profiles.public_user_id bigint` is a permanent display/administrative identifier. Values begin at 10000001 and come from `profiles_public_user_id_seq`. A `SECURITY DEFINER` insert trigger always assigns the value, so browser roles receive no sequence permission and cannot choose an ID. A second trigger rejects every later change. The UUID remains the authentication and relationship key.

### Lesson video source

Lessons retain the existing `video_url` and `video_provider` fields for uploaded/Cloudflare sources and add:

- `youtube_video_id varchar(11)` — normalized allowlisted identifier
- `video_original_url text` — administrator input retained for editing/audit

The database trigger accepts common watch, short, embed, Shorts, Live, privacy-domain URLs, or an 11-character ID. A YouTube lesson stores `video_provider = 'youtube'`, clears `video_url`, and builds playback URLs only as `https://www.youtube-nocookie.com/embed/{id}`. No administrator HTML is rendered.

Unlisted YouTube is discoverability control, not DRM. Anyone who obtains the original link may watch outside MedBank. MedBank authorization protects lesson records/pages but cannot make YouTube content private.

### Access and coupons

- `platform_course_enrollments.access_scope`: `full` or `partial`
- `platform_course_enrollments.access_source`: `manual`, `coupon`, `request`, `payment`, `legacy`, or `other`
- Existing enrollment rows were backfilled to `full/manual`.
- Full access includes current and future published modules.
- `platform_course_module_entitlements` stores additive module grants. Full access overrides them.
- Multiple module coupons merge through unique `(user_id,module_id)` grants. They never downgrade full access.
- `platform_course_coupons` stores only SHA-256 hashes plus a four-character preview. Plain codes are returned once by generation.
- `platform_course_coupon_modules` links a module coupon to one or more modules in its course.
- `platform_course_coupon_redemptions` is the immutable audit record.

`redeem_platform_course_coupon(text)` uses `auth.uid()`, hashes the normalized code, locks the matching coupon `FOR UPDATE`, validates account/course/module state, grants access, writes the audit row, and marks the coupon redeemed in one transaction. Stable failures are returned as structured JSON.

### Lesson authorization

The private access helpers are the single database truth:

- `private.has_full_platform_course_access(course_id)`
- `private.has_any_platform_course_access(course_id)`
- `private.has_platform_module_access(module_id)`
- `private.can_access_platform_lesson(lesson_id)`

Course and module metadata can be shown for an entitled or suggested course so locked modules are visible. Protected lesson and resource rows are returned only for an entitled module/full course; free preview lessons remain available to eligible students. Progress writes call the lesson helper. Private video objects no longer have student SELECT access; `course-video-url` validates the exact lesson and returns a one-hour signed URL. Cloudflare Stream applies the same full/module rule.

## Database objects

Created:

- sequence `profiles_public_user_id_seq`
- column `profiles.public_user_id`
- columns `platform_course_lessons.youtube_video_id`, `video_original_url`
- columns `platform_course_enrollments.access_scope`, `access_source`, `source_coupon_id`
- tables `platform_course_coupons`, `platform_course_coupon_modules`, `platform_course_coupon_redemptions`, `platform_course_module_entitlements`
- admin RPCs `admin_find_profile_by_public_user_id`, `admin_generate_platform_course_coupons`, `admin_disable_platform_course_coupon`, `admin_list_platform_course_coupons`, `admin_get_platform_course_coupon_stats`
- student RPCs `redeem_platform_course_coupon`, `get_my_platform_course_access`
- YouTube helpers `normalize_youtube_video_id`, `youtube_privacy_embed_url`
- private access, validation, numeric-ID, and coupon helper functions/triggers
- RLS policies and lookup/reporting indexes defined in the migration

Created Edge Function: `course-video-url`. Updated Edge Function: `cloudflare-stream-token`.

## Manual QA

### Student

1. Sign in as an approved student and open Profile. Confirm the numeric MedBank ID, copy it, and see “User ID copied.”
2. Open Video Courses, choose Activate Course, submit invalid, expired, disabled, and used codes; verify friendly messages and no raw database detail.
3. Redeem a full coupon. Confirm one submit, immediate success, navigation to the course, and all modules unlocked.
4. Redeem a module coupon on another account. Confirm the course is in My Courses, selected modules open, and other modules show Locked.
5. Redeem a second module coupon and confirm grants merge.
6. Open uploaded, Cloudflare (when enabled), and YouTube lessons. Confirm denied users cannot query/open protected lessons and the YouTube iframe uses `youtube-nocookie.com`.
7. Complete a YouTube lesson and confirm existing progress behavior remains intact.
8. Repeat at 375 px width and with keyboard-only navigation; Escape/Close should dismiss the activation dialog and focus labels should remain usable.

### Administrator

1. Search Users and Video Course enrollment pickers by exact MedBank ID; confirm the correct student and displayed ID.
2. Create/edit a lesson with each supported YouTube URL shape. Confirm live preview, normalized ID after save, and clear rejection of non-YouTube/invalid links.
3. Replace YouTube with an upload, replace an upload with YouTube, and remove a video.
4. Open Video Courses → Activation Coupons. Generate one full code and a bulk batch; copy and download codes before navigating away.
5. Generate a multi-module coupon. Verify plaintext is absent from the later coupon table and only its preview remains.
6. Exercise course/type/status/date/student-ID/batch filters, report export, disable an unused coupon, and open a redeemed student.
7. Compare totals, redemption rate, time series, module counts, and recent redemption rows against the generated test batch.

## Operations

```bash
supabase db push --linked --dns-resolver https
supabase functions deploy course-video-url --project-ref fzjzjzdamehxbgikiskt --no-verify-jwt
supabase functions deploy cloudflare-stream-token --project-ref fzjzjzdamehxbgikiskt --no-verify-jwt
npm test
npm run lint
npm run build
python3 -m http.server 4173
```

Database integration tests (all fixtures roll back):

```bash
supabase db query --linked --file supabase/tests/20260804_video_courses_features.sql
```

Rollback is intentionally not automatic after real redemptions because removing entitlements would revoke purchased/issued access. Before launch, the migration can be reversed by dropping the new policies/functions/tables/columns and restoring the preceding policies. After launch, take a database backup and perform a data-aware migration; never drop redemption/access data blindly.
