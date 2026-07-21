# MedBank — Canonical naming: Video Courses vs MCQ Subjects

**Status:** authoritative as of 2026-07-21. Any agent or developer touching
MedBank must follow this vocabulary. If you find the bare word "Courses" in code
or UI, it is a bug — fix it to one of the two names below.

---

## The problem this solves

MedBank contains **two completely unrelated products** that were both called
"Courses". They share no tables, no access flags, and no routes. Students were
confused, and AI agents (including the Flutter app agent) merged them into a
single concept and produced wrong code.

They are not two views of one thing. They are two products.

---

## 1. Video Courses (the LMS)

The video learning platform: lectures, modules, lessons, announcements,
enrollment requests.

| Aspect | Value |
|---|---|
| **User-facing name** | **Video Courses** (never bare "Courses") |
| **Web route** | `video-courses` (legacy `courses` still redirects) |
| **Admin page id** | `video-courses` (legacy `course-platform` still redirects) |
| **Tables** | `platform_courses`, `platform_course_enrollments`, `platform_*` |
| **Access flag** | `profiles.courses_access_enabled` |
| **Availability flag** | app feature flag — "coming soon" gate |
| **Video pipeline** | Cloudflare Stream (parked) → Supabase Storage fallback |

A unit of this product is a **course** (e.g. "Cardiology Lecture Series").

## 2. MCQ Bank / MCQ Subjects (the question bank)

The exam-practice product: question banks, test blocks, timed/tutor sessions,
analytics.

| Aspect | Value |
|---|---|
| **Product name** | **MCQ Bank** |
| **Name for a curriculum unit** | **MCQ Subject** (never "course") |
| **Web routes** | `dashboard`, `create-test`, `session`, `review`, `analytics` |
| **Admin page id** | `mcq-subjects` (legacy `courses` still redirects) |
| **Tables** | `courses`, `course_topics` — *legacy names, do not rename* |
| **Alias views** | `mcq_subjects`, `mcq_subject_topics` — **prefer these** |
| **Access flag** | `profiles.mcq_access_enabled` |
| **Enrollment field** | `profiles.assigned_courses` → "assigned MCQ subjects" |

A unit of this product is an **MCQ subject** (e.g. "Gynecology", "BOS 101").

---

## ⚠️ The trap

The MCQ side's tables are still named `courses` / `course_topics` for historical
reasons. **`public.courses` is NOT the video course table.**

```
public.courses           -> MCQ SUBJECTS   (question bank)
public.platform_courses  -> VIDEO COURSES  (the LMS)
```

Renaming those tables was evaluated and rejected: `courses` carries 34 RLS
policies, 12 FK constraints and 12 SQL functions, and rewriting them risks an
access-control regression on live student data.

Instead, read-only `security_invoker` views exist as self-documenting aliases:

```sql
select * from public.mcq_subjects;        -- = public.courses
select * from public.mcq_subject_topics;  -- = public.course_topics
```

**Use the alias views for all new read paths.** Writes must still target the
real tables (`courses` / `course_topics`), because the views are read-only.

---

## Instruction block for the Flutter app agent

> Copy this verbatim into the Flutter agent's brief / system prompt.

```
MedBank has TWO separate products. Never merge, alias, or share models between
them. They have different tables, different access flags, and different screens.

PRODUCT 1 — "Video Courses" (video learning platform / LMS)
  - Display name in the app: exactly "Video Courses". Never "Courses".
  - Data: Supabase tables platform_courses, platform_course_enrollments, and
    the other platform_* tables.
  - Gated by: profiles.courses_access_enabled
  - Screens: course list, module/lesson list, video player, announcements,
    access requests.
  - Dart naming: VideoCourse, VideoCourseRepository, VideoCoursesScreen.

PRODUCT 2 — "MCQ Bank", whose units are called "MCQ Subjects"
  - Display name of the product: exactly "MCQ Bank".
  - Display name of one curriculum unit: exactly "MCQ Subject". Never "course".
  - Data: Supabase tables courses and course_topics. WARNING: these legacy table
    names say "courses" but they are the MCQ QUESTION BANK, not the video LMS.
    Prefer the read-only alias views mcq_subjects and mcq_subject_topics for
    reads; write to courses/course_topics.
  - Gated by: profiles.mcq_access_enabled
  - Screens: dashboard, create test, exam session, review, analytics.
  - Dart naming: McqSubject, McqSubjectRepository, McqBankScreen.

HARD RULES
  1. Never name a Dart class, file, route, or widget just "Course" or
     "CoursesScreen". Always prefix: VideoCourse* or McqSubject*.
  2. Never let a single model, provider, or repository serve both products.
  3. profiles.assigned_courses lists MCQ SUBJECTS, not video courses. Video
     course enrollment lives in platform_course_enrollments.
  4. The two access flags are independent. A student can have MCQ Bank access
     with Video Courses disabled, or the reverse. Never gate one on the other.
  5. Route ids to mirror from the web app: "video-courses" for the LMS; the MCQ
     side uses "dashboard" / "create-test" / "session" / "review" / "analytics".
  6. If a requirement says only "courses", STOP and ask which product is meant.
     Do not guess.
```

---

## Legacy id compatibility

`main.js` maps old ids forward via `canonicalizeRoute()` /
`canonicalizeAdminPage()`, so existing bookmarks, saved route memory, and any
already-shipped mobile build keep working:

| Legacy | Canonical |
|---|---|
| route `courses` | `video-courses` |
| admin page `courses` | `mcq-subjects` |
| admin page `course-platform` | `video-courses` |

These aliases are a migration aid. Emit only canonical ids in new code.
