-- Signed-in access checks against the hosted project. Acts as a real
-- approved student, an unapproved student and an admin (by setting the JWT
-- claims auth.uid() reads), checks what each can see and change, and always
-- rolls back. Raises one error listing every failure. Run with
-- `npm run check:rls` (build/check-rls.mjs).
begin;

do $$
declare
  student uuid;
  pending uuid;
  pending_before text;
  admin uuid;
  failures text[] := '{}';
  n bigint;
  student_readable_globals text[] := array[
    'g:mcq_site_maintenance', 'g:support_whatsapp', 'g:mcq_course_topic_groups',
    'g:mcq_course_notebook_links', 'g:mcq_topic_new_catalog',
    'g:mcq_auto_approve_student_access', 'g:mcq_student_refresh_trigger'
  ];
begin
  -- Pick users as the table owner, before switching role.
  select p.id into student from public.profiles p
   where p.role = 'student' and p.approved and p.mcq_access_enabled
     and exists (select 1 from public.app_state s where s.storage_key like 'u:' || p.id || ':%')
     and exists (select 1 from public.test_history_entries t where t.user_id = p.id)
   order by p.created_at limit 1;
  select p.id into pending from public.profiles p
   where p.role = 'student' and not p.approved order by p.created_at limit 1;
  select p.id into admin from public.profiles p where p.role = 'admin' order by p.created_at limit 1;
  if student is null or admin is null then
    raise exception 'RLS check setup: no approved student with data, or no admin';
  end if;

  ---------------------------------------------------------------- student
  perform set_config('request.jwt.claims',
    json_build_object('sub', student, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.app_state
   where storage_key like 'u:%' and storage_key not like 'u:' || student || ':%';
  if n > 0 then failures := array_append(failures, format('student reads %s other users'' app_state rows', n)::text); end if;

  select count(*) into n from public.app_state
   where storage_key not like 'u:%' and not (storage_key = any (student_readable_globals));
  if n > 0 then failures := array_append(failures, format('student reads %s admin-only app_state keys', n)::text); end if;

  select count(*) into n from public.app_state where storage_key like 'u:' || student || ':%';
  if n = 0 then failures := array_append(failures, 'student cannot read own app_state rows'::text); end if;

  begin
    insert into public.app_state (storage_key, payload) values ('g:rls_check_probe', '{}'::jsonb);
    failures := array_append(failures, 'student can insert a g: app_state key'::text);
  exception when insufficient_privilege then null;
  end;

  update public.app_state set payload = payload where storage_key = 'g:mcq_site_maintenance';
  get diagnostics n = row_count;
  if n > 0 then failures := array_append(failures, 'student can update g:mcq_site_maintenance'::text); end if;

  select count(*) into n from public.profiles where id <> student;
  if n > 0 then failures := array_append(failures, format('student reads %s other profiles', n)::text); end if;

  select count(*) into n from public.test_history_entries where user_id <> student;
  if n > 0 then failures := array_append(failures, format('student reads %s other users'' test history rows', n)::text); end if;
  select count(*) into n from public.test_history_entries where user_id = student;
  if n = 0 then failures := array_append(failures, 'student cannot read own test history'::text); end if;

  select count(*) into n from public.test_blocks where user_id <> student;
  if n > 0 then failures := array_append(failures, format('student reads %s other users'' test blocks', n)::text); end if;

  select count(*) into n from public.user_course_enrollments where user_id <> student;
  if n > 0 then failures := array_append(failures, format('student reads %s other users'' enrollments', n)::text); end if;

  select count(*) into n from public.questions where status <> 'published';
  if n > 0 then failures := array_append(failures, format('student reads %s unpublished questions', n)::text); end if;

  begin
    update public.profiles set role = 'admin' where id = student;
  exception when others then null;
  end;
  if exists (select 1 from public.profiles where id = student and role = 'admin') then
    failures := array_append(failures, 'student can make themselves admin'::text);
  end if;

  reset role;

  ---------------------------------------------------------------- pending
  if pending is not null then
    select format('%s/%s', approved, mcq_access_enabled) into pending_before
      from public.profiles where id = pending;
    perform set_config('request.jwt.claims',
      json_build_object('sub', pending, 'role', 'authenticated')::text, true);
    set local role authenticated;

    select count(*) into n from public.questions;
    if n > 0 then failures := array_append(failures, format('unapproved student reads %s questions', n)::text); end if;

    begin
      update public.profiles set approved = true, mcq_access_enabled = true where id = pending;
    exception when others then null;
    end;
    reset role;
    if (select format('%s/%s', approved, mcq_access_enabled) from public.profiles where id = pending)
       is distinct from pending_before then
      failures := array_append(failures, 'unapproved student can approve themselves'::text);
    end if;
  end if;

  ---------------------------------------------------------------- admin
  perform set_config('request.jwt.claims',
    json_build_object('sub', admin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.app_state where storage_key = 'g:mcq_questions';
  if n = 0 then failures := array_append(failures, 'admin cannot read g:mcq_questions'::text); end if;

  select count(*) into n from public.profiles where id <> admin;
  if n = 0 then failures := array_append(failures, 'admin cannot read other profiles'::text); end if;

  reset role;

  if cardinality(failures) > 0 then
    raise exception 'RLS check failed: %', array_to_string(failures, '; ');
  end if;
end
$$;

rollback;
