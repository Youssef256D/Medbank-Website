-- Recovered from the hosted migration ledger on 2026-09-20: applied to the
-- hosted project but never committed. Contents are what the ledger recorded.

-- Creator Studio uploads: cover images and course materials.
--
-- The course-covers and course-materials buckets were created for the website
-- admin uploader, so every policy on them tests private.is_admin_user(). A
-- course creator uploading from the app therefore failed the RLS check on
-- insert, and could not read back an object they had just written.

create or replace function private.storage_course_id(object_name text)
returns uuid
language sql
stable
set search_path to ''
as $$
  select case
    when (storage.foldername(object_name))[1] = 'courses'
      and coalesce((storage.foldername(object_name))[2], '') ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then ((storage.foldername(object_name))[2])::uuid
  end;
$$;

drop policy if exists course_covers_creator_all on storage.objects;
create policy course_covers_creator_all
  on storage.objects
  for all
  to authenticated
  using (
    bucket_id = 'course-covers'
    and private.owns_platform_course(private.storage_course_id(name))
  )
  with check (
    bucket_id = 'course-covers'
    and private.owns_platform_course(private.storage_course_id(name))
  );

drop policy if exists course_materials_creator_all on storage.objects;
create policy course_materials_creator_all
  on storage.objects
  for all
  to authenticated
  using (
    bucket_id = 'course-materials'
    and private.owns_platform_course(private.storage_course_id(name))
  )
  with check (
    bucket_id = 'course-materials'
    and private.owns_platform_course(private.storage_course_id(name))
  );

drop policy if exists course_materials_student_select_visible_module
  on storage.objects;
create policy course_materials_student_select_visible_module
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'course-materials'
    and (storage.foldername(name))[1] = 'courses'
    and (storage.foldername(name))[3] = 'modules'
    and coalesce((storage.foldername(name))[4], '') ~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    and private.has_platform_module_access(
      ((storage.foldername(name))[4])::uuid
    )
  );
