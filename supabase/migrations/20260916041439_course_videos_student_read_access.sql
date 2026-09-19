-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- The course-videos bucket carried only admin policies, so a student could never
-- mint a signed URL for a MedBank-hosted lesson video. Latent today (every live
-- lesson is YouTube and the bucket holds only an empty-folder placeholder), but the
-- first self-hosted video would have been unplayable for every student.
--
-- Access is keyed to the lesson that REFERENCES the object rather than to a folder
-- convention: no real video has been uploaded yet, so no path convention is
-- established, and "you may read this file if you may access the lesson that uses
-- it" is the rule we actually mean. Suffix match with right() rather than LIKE so
-- an underscore in a filename cannot act as a wildcard.

create or replace function private.can_read_platform_course_video(object_name text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select private.is_active_platform_student()
    and object_name is not null
    and exists (
      select 1
      from public.platform_course_lessons l
      where l.video_url is not null
        and (
          l.video_url = 'supabase-storage://course-videos/' || object_name
          or right(l.video_url, length(object_name) + 15)
               = '/course-videos/' || object_name
        )
        and private.can_access_platform_lesson(l.id)
    );
$function$;

drop policy if exists course_videos_student_select_accessible_lesson on storage.objects;

create policy course_videos_student_select_accessible_lesson
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'course-videos'
    and private.can_read_platform_course_video(name)
  );
