# Flutter integration: Video Courses IDs, YouTube, and coupons

This is the implementation contract for the Flutter app that shares MedBank's Supabase project. It targets feature version `2026-08-04.06` and requires migrations `20260804205400_add_video_course_ids_youtube_coupons.sql` and `20260804211839_fix_platform_coupon_generator_encode.sql`.

## 1. Identity

Keep `auth.users.id` / `profiles.id` (UUID) as the internal user key. Never replace foreign keys with the display ID.

`profiles.public_user_id bigint not null unique` is assigned by the database on profile INSERT, begins at 10000001, and is immutable. Do not send it in an insert/update payload. Read it with the signed-in user's profile and render it as an integer string.

```dart
final profile = await supabase.from('profiles')
  .select('id,public_user_id,full_name,email,phone,role,approved,courses_access_enabled')
  .eq('id', supabase.auth.currentUser!.id)
  .single();
```

Suggested model field: `final int publicUserId;`. Provide a copy button and local confirmation. Admin lookup by exact ID is:

```dart
final rows = await supabase.rpc('admin_find_profile_by_public_user_id', params: {
  'p_public_user_id': publicUserId,
});
```

Only a trusted database admin role can execute a successful lookup; do not emulate it with a broad client-side profile query.

## 2. Schema and relationships

Existing:

- `platform_courses.id` → course
- `platform_course_modules.id`, `.course_id` → ordered modules
- `platform_course_lessons.id`, `.course_id`, `.module_id` → ordered lessons
- `platform_course_enrollments(user_id, course_id)` → course membership
- `platform_lesson_progress(user_id, lesson_id)` → progress

Added lesson fields:

- `video_provider text`: `youtube`, `supabase_storage`, `cloudflare_stream`, or existing source
- `youtube_video_id varchar(11)`
- `video_original_url text`

Added enrollment fields:

- `access_scope text`: `full` or `partial`
- `access_source text`: `manual`, `coupon`, `request`, `payment`, `legacy`, `other`
- `source_coupon_id uuid?`

Coupon tables:

- `platform_course_coupons`: course, hash, preview, type, enabled/expiry, creator, redemption/disable actors and timestamps, batch/note
- `platform_course_coupon_modules(coupon_id,module_id)`
- `platform_course_coupon_redemptions`: coupon/user/course/access type/module snapshot/time
- `platform_course_module_entitlements`: user/course/module, grant source, source coupon, grant actor/time

The client must not query `platform_course_coupons`; privileges are revoked. Admin management goes through RPCs. Students may read only their own redemption and entitlement rows.

## 3. Access rules

1. A `full` enrollment unlocks every current and future published module.
2. Otherwise, a published module is unlocked only when its ID appears in the user's module entitlements.
3. Multiple entitlement rows merge; never replace the set after one redemption.
4. Full access always wins. A module coupon returns `ALREADY_HAS_ACCESS` for an already-full user and remains unused.
5. A partial enrollment makes the course appear in My Courses. Locked module metadata may render, but protected lesson rows are withheld by RLS.
6. Free previews remain available for eligible suggested courses.
7. Account approval, `courses_access_enabled`, global course availability, course active/published, module published, and lesson published conditions still apply.

Load the authoritative access snapshot:

```dart
final accessRows = await supabase.rpc('get_my_platform_course_access');
```

Response rows:

```json
{
  "course_id": "uuid",
  "access_scope": "full|partial",
  "access_source": "manual|coupon|request|payment|legacy|other",
  "module_ids": ["uuid"]
}
```

Recommended resolver:

```dart
bool moduleUnlocked(CourseAccess access, String moduleId) =>
    access.scope == AccessScope.full || access.moduleIds.contains(moduleId);
```

Do not infer authorization only from this snapshot. Query lessons normally and let RLS be the final enforcement layer.

## 4. Coupon redemption

Normalize presentation by trimming, uppercasing, and permitting spaces/hyphens. Do not hash in Flutter; send the entered code over TLS to:

```dart
final result = await supabase.rpc('redeem_platform_course_coupon', params: {
  'p_code': enteredCode,
});
```

Success:

```json
{
  "ok": true,
  "code": "SUCCESS",
  "course_id": "uuid",
  "course_name": "Physiology",
  "access_type": "full_course|module_access",
  "module_ids": ["uuid"],
  "module_titles": ["Chapter 1"]
}
```

Failure always has `ok: false` and one stable code:

- `INVALID_COUPON`
- `COUPON_ALREADY_USED`
- `COUPON_EXPIRED`
- `COUPON_DISABLED`
- `COURSE_UNAVAILABLE`
- `MODULE_UNAVAILABLE`
- `ALREADY_HAS_ACCESS`
- `UNAUTHORIZED`
- `REDEMPTION_FAILED`

Map these locally to friendly copy. Never show exception details. Disable submission while awaiting the RPC. On success, invalidate course catalog, access snapshot, enrollment, module, lesson, announcement, and progress caches; refetch access and My Courses; then offer navigation to `course_id`. For partial success, show `module_titles`.

Suggested classes:

```dart
enum CourseAccessScope { none, partial, full }
enum CouponAccessType { fullCourse, moduleAccess }

class CourseAccess {
  final String courseId;
  final CourseAccessScope scope;
  final String source;
  final Set<String> moduleIds;
}

class CouponRedemptionResult {
  final bool ok;
  final String code;
  final String? courseId;
  final String? courseName;
  final CouponAccessType? accessType;
  final List<String> moduleIds;
  final List<String> moduleTitles;
}
```

Suggested services:

- `ProfileRepository`: own profile/public ID and admin exact-ID lookup
- `VideoCourseRepository`: catalog, modules, lessons, progress, access snapshot, cache invalidation
- `CourseCouponService`: redemption and stable error mapping
- `AdminCourseCouponRepository`: generation/list/disable/statistics
- `CourseVideoService`: signed uploaded/Cloudflare URL requests

Suggested student widgets/screens:

- `MedBankIdCard`
- `ActivateCourseButton` and `CouponActivationSheet`
- `CourseAccessBadge` (`Full course` / `N modules`)
- `CourseModuleTile(locked: ...)`
- `YouTubeLessonPlayer`

States: initial/loading, validation error, submitting, success, known server failure, retryable network failure, and empty My Courses. Preserve the entered code only for network failures; clear it on success.

## 5. YouTube lessons

The database is authoritative, but an admin mobile form may provide immediate validation. Accept:

- `youtube.com/watch?v={11-char-id}`
- `youtu.be/{id}`
- `youtube.com/embed/{id}`
- `youtube.com/shorts/{id}`
- `youtube.com/live/{id}`
- privacy-domain embeds or a raw valid ID

Only `[A-Za-z0-9_-]{11}` is valid. Send:

```json
{
  "video_provider": "youtube",
  "youtube_video_id": "dQw4w9WgXcQ",
  "video_original_url": "https://youtu.be/dQw4w9WgXcQ",
  "video_url": null
}
```

The database trigger normalizes/rejects the payload. Build playback only from the normalized ID on `https://www.youtube-nocookie.com/embed/{id}`. Never render arbitrary HTML or use the original URL as a WebView source. Use a maintained Flutter player capable of YouTube iframe playback and privacy-domain configuration; choose the package during mobile implementation based on current project/platform support rather than hardcoding one here. Include 16:9 sizing, loading, invalid/missing ID, embedding-disabled/unavailable, lifecycle pause, and network retry states.

Unlisted YouTube is not DRM. Document this in the admin UI and operational guidance.

Uploaded private video URL request:

```http
POST /functions/v1/course-video-url
Authorization: Bearer <user JWT>
apikey: <publishable key>
Content-Type: application/json

{"lessonId":"uuid"}
```

Success: `{ "ok": true, "signedUrl": "...", "expiresInSeconds": 3600 }`. The function validates admin/full/module/free-preview access. Cache only until shortly before expiry and never persist the signed URL long-term. Cloudflare uses the existing `cloudflare-stream-token` endpoint with the same lesson ID and access rules.

## 6. Admin coupon RPCs

Generate (quantity 1–500):

```dart
final created = await supabase.rpc('admin_generate_platform_course_coupons', params: {
  'p_course_id': courseId,
  'p_coupon_type': 'full_course', // or module_access
  'p_module_ids': moduleIds,
  'p_quantity': quantity,
  'p_expires_at': expiresAt?.toUtc().toIso8601String(),
  'p_batch_name': batchName,
  'p_note': note,
});
```

Each returned row contains `coupon_id`, one-time `coupon_code`, `code_preview`, `coupon_type`, `course_id`, `module_ids`, `expires_at`, `batch_name`, `created_at`. Immediately copy/export plaintext; it is not recoverable.

List/filter:

```dart
await supabase.rpc('admin_list_platform_course_coupons', params: {
  'p_course_id': courseId,
  'p_coupon_type': null,
  'p_status': 'all',
  'p_search': search,
  'p_created_from': createdFrom,
  'p_created_to': createdTo,
  'p_redeemed_from': redeemedFrom,
  'p_redeemed_to': redeemedTo,
  'p_limit': 100,
  'p_offset': 0,
});
```

Rows include derived `status` (`used`, `disabled`, `expired`, `unused`), redeemed student UUID/public ID/name, module arrays, and `total_count`.

Disable unused:

```dart
await supabase.rpc('admin_disable_platform_course_coupon', params: {
  'p_coupon_id': couponId,
});
```

Statistics:

```dart
final stats = await supabase.rpc('admin_get_platform_course_coupon_stats', params: {
  'p_course_id': courseId,
});
```

It returns totals, full/module counts, redeemed/unused/expired/disabled/students, `redemption_rate`, `redemptions_over_time`, `redemptions_by_module`, and `recent_redemptions`. Calculate no totals by downloading all coupons.

Suggested admin UI: course selector, access type segmented control, multi-module selector, quantity/expiry/batch/note inputs, one-time result sheet with copy/export, filters, paginated table, disable confirmation, statistics cards/time series/module ranking, and redemption-to-profile navigation.

## 7. RLS and security expectations

- Use only the publishable/anon key in Flutter.
- Never ship the service-role key or coupon hashing logic.
- Never accept a user UUID in redemption; the RPC uses `auth.uid()`.
- Students cannot list hashes/coupons, mutate coupon state, create entitlements, or edit public IDs.
- Admin status comes from `profiles.role` inside database functions/RLS, not a client boolean.
- Treat the RPC response as the access mutation result and RLS as the content gate.
- Redact coupon plaintext, access tokens, signed video URLs, and hashes from analytics/crash logs.
- Do not silently reassign or delete used coupons.

## 8. Backwards compatibility

- Existing UUIDs, foreign keys, routes, progress, uploads, and full enrollments remain valid.
- All pre-migration enrollment rows are `full/manual`.
- Older clients that only check for an enrollment row will show a partial course in My Courses, but may incorrectly unlock all modules. Therefore mobile builds must adopt the access snapshot/module resolver before module coupons are distributed to mobile users.
- Older clients ignore YouTube fields and show no video because YouTube rows intentionally have `video_url = null`; update playback before administrators publish YouTube lessons to mobile users.
- Full-course coupons are compatible with existing enrollment-based My Courses behavior, but the new stable errors and refresh flow still require an updated client.
