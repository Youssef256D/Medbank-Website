-- Recovered from the hosted migration ledger (supabase_migrations.schema_migrations)
-- on 2026-09-20: this was applied to the hosted project but never committed.
-- Contents are byte-for-byte what the hosted project recorded.

create or replace function private.is_platform_module_published(target_module_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.platform_course_modules m
    where m.id = target_module_id
      and m.is_published is true
  );
$function$;

drop policy if exists platform_lessons_select_student_visible on public.platform_course_lessons;

create policy platform_lessons_select_student_visible
  on public.platform_course_lessons
  for select
  to authenticated
  using (
    is_published is true
    and (
      private.has_platform_module_access(module_id)
      or (
        is_free_preview is true
        and private.is_platform_module_published(module_id)
        and private.can_select_platform_course_by_id(course_id)
      )
    )
  );
