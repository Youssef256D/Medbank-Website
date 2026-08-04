-- Run with: supabase db query --linked --file supabase/tests/20260804_video_courses_features.sql
-- All fixtures and access changes are rolled back.
begin;

do $test$
declare
  admin_id uuid;
  student_a uuid;
  student_b uuid;
  target_course_id uuid;
  module_a uuid;
  module_b uuid;
  full_code text;
  module_code_a text;
  module_code_b text;
  disabled_code text;
  already_code text;
  result jsonb;
  coupon_id uuid;
  original_public_id bigint;
  stats jsonb;
begin
  if exists (select 1 from public.profiles where public_user_id is null)
     or (select count(*) from public.profiles) <> (select count(distinct public_user_id) from public.profiles) then
    raise exception 'Numeric public user ID backfill is incomplete or duplicated';
  end if;

  if public.normalize_youtube_video_id('https://www.youtube.com/watch?v=dQw4w9WgXcQ') <> 'dQw4w9WgXcQ'
     or public.normalize_youtube_video_id('https://youtu.be/dQw4w9WgXcQ?t=3') <> 'dQw4w9WgXcQ'
     or public.normalize_youtube_video_id('https://youtube.com/embed/dQw4w9WgXcQ') <> 'dQw4w9WgXcQ'
     or public.normalize_youtube_video_id('https://youtube.com/shorts/dQw4w9WgXcQ') <> 'dQw4w9WgXcQ'
     or public.normalize_youtube_video_id('https://example.com/watch?v=dQw4w9WgXcQ') is not null then
    raise exception 'YouTube normalization assertion failed';
  end if;

  select p.id into admin_id from public.profiles p where p.role = 'admin' order by p.created_at limit 1;
  select source.id, source.module_ids[1], source.module_ids[2]
  into target_course_id, module_a, module_b
  from (
    select c.id, array_agg(m.id order by m.position, m.id::text) as module_ids
    from public.platform_courses c
    join public.platform_course_modules m on m.course_id = c.id and m.is_published is true
    where c.is_active is true and c.is_published is true
    group by c.id
    having count(*) >= 2
    limit 1
  ) source;
  if admin_id is null or target_course_id is null or module_a = module_b then
    raise exception 'Integration fixtures require an admin and a published course with two modules';
  end if;

  select p.id into student_a
  from public.profiles p
  where p.role = 'student' and p.approved is true and p.courses_access_enabled is true
    and not exists (select 1 from public.platform_course_enrollments e where e.user_id = p.id and e.course_id = target_course_id)
    and not exists (select 1 from public.platform_course_module_entitlements me where me.user_id = p.id and me.course_id = target_course_id)
  order by p.created_at limit 1;
  select p.id into student_b
  from public.profiles p
  where p.role = 'student' and p.approved is true and p.courses_access_enabled is true and p.id <> student_a
    and not exists (select 1 from public.platform_course_enrollments e where e.user_id = p.id and e.course_id = target_course_id)
    and not exists (select 1 from public.platform_course_module_entitlements me where me.user_id = p.id and me.course_id = target_course_id)
  order by p.created_at limit 1;
  if student_a is null or student_b is null then raise exception 'Two eligible student fixtures were not found'; end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  select generated.coupon_code into full_code
  from public.admin_generate_platform_course_coupons(target_course_id, 'full_course', '{}'::uuid[], 1, now() + interval '1 day', 'integration-test', null) generated;
  select generated.coupon_code into module_code_a
  from public.admin_generate_platform_course_coupons(target_course_id, 'module_access', array[module_a], 1, null, 'integration-test', null) generated;
  select generated.coupon_code into module_code_b
  from public.admin_generate_platform_course_coupons(target_course_id, 'module_access', array[module_b], 1, null, 'integration-test', null) generated;
  select generated.coupon_code into disabled_code
  from public.admin_generate_platform_course_coupons(target_course_id, 'full_course', '{}'::uuid[], 1, null, 'integration-test', null) generated;
  select c.id into coupon_id from public.platform_course_coupons c where c.code_hash = extensions.digest(private.normalize_platform_coupon_code(disabled_code), 'sha256');
  result := public.admin_disable_platform_course_coupon(coupon_id);
  if result->>'code' <> 'SUCCESS' then raise exception 'Admin disable failed: %', result; end if;

  -- Non-admin generation must fail inside the trusted function.
  perform set_config('request.jwt.claim.sub', student_a::text, true);
  begin
    perform * from public.admin_generate_platform_course_coupons(target_course_id, 'full_course', '{}'::uuid[], 1, null, null, null);
    raise exception 'Non-admin coupon generation unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;

  result := public.redeem_platform_course_coupon(full_code);
  if result->>'code' <> 'SUCCESS' then raise exception 'Full-course redemption failed: %', result; end if;
  if not exists (select 1 from public.platform_course_enrollments e where e.user_id = student_a and e.course_id = target_course_id and e.access_scope = 'full') then
    raise exception 'Full-course enrollment was not created';
  end if;
  if not exists (select 1 from public.platform_course_coupon_redemptions r where r.user_id = student_a and r.course_id = target_course_id and r.access_type = 'full_course') then
    raise exception 'Full-course audit record missing';
  end if;
  result := public.redeem_platform_course_coupon(full_code);
  if result->>'code' <> 'COUPON_ALREADY_USED' then raise exception 'Coupon reuse was not rejected: %', result; end if;

  -- A module coupon never downgrades or consumes against existing full access.
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  select generated.coupon_code into already_code
  from public.admin_generate_platform_course_coupons(target_course_id, 'module_access', array[module_a], 1, null, 'integration-test', null) generated;
  perform set_config('request.jwt.claim.sub', student_a::text, true);
  result := public.redeem_platform_course_coupon(already_code);
  if result->>'code' <> 'ALREADY_HAS_ACCESS' then raise exception 'Full access was not preserved: %', result; end if;
  if not exists (select 1 from public.platform_course_enrollments e where e.user_id = student_a and e.course_id = target_course_id and e.access_scope = 'full') then
    raise exception 'Module redemption downgraded full access';
  end if;

  -- Two module coupons merge additively for another user.
  perform set_config('request.jwt.claim.sub', student_b::text, true);
  result := public.redeem_platform_course_coupon(module_code_a);
  if result->>'code' <> 'SUCCESS' then raise exception 'First module redemption failed: %', result; end if;
  result := public.redeem_platform_course_coupon(module_code_b);
  if result->>'code' <> 'SUCCESS' then raise exception 'Second module redemption failed: %', result; end if;
  if (select count(*) from public.platform_course_module_entitlements me where me.user_id = student_b and me.course_id = target_course_id and me.module_id in (module_a, module_b)) <> 2 then
    raise exception 'Module entitlements did not merge';
  end if;
  if not private.has_platform_module_access(module_a) or not private.has_platform_module_access(module_b) then
    raise exception 'Central module access resolver rejected valid grants';
  end if;

  result := public.redeem_platform_course_coupon(disabled_code);
  if result->>'code' <> 'COUPON_DISABLED' then raise exception 'Disabled coupon was not rejected: %', result; end if;

  insert into public.platform_course_coupons (course_id, code_hash, code_preview, coupon_type, expires_at, created_by)
  values (target_course_id, extensions.digest('MBKEXPIREDTESTCODE23456789', 'sha256'), '6789', 'full_course', now() - interval '1 hour', admin_id);
  result := public.redeem_platform_course_coupon('MBK-EXPIRED-TEST-CODE-2345-6789');
  if result->>'code' <> 'COUPON_EXPIRED' then raise exception 'Expired coupon was not rejected: %', result; end if;

  select p.public_user_id into original_public_id from public.profiles p where p.id = student_a;
  begin
    update public.profiles set public_user_id = original_public_id + 999999 where id = student_a;
    raise exception 'Immutable public ID update unexpectedly succeeded';
  exception when check_violation then
    null;
  end;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  stats := public.admin_get_platform_course_coupon_stats(target_course_id);
  if coalesce((stats->>'total')::integer, 0) < 6 or coalesce((stats->>'redeemed')::integer, 0) < 3 then
    raise exception 'Coupon statistics did not include test generation/redemptions: %', stats;
  end if;
end;
$test$;

rollback;
