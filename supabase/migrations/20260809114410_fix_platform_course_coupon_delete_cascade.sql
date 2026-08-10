begin;

-- Course deletion is the aggregate boundary for the Video Courses platform.
-- The original coupon migration used RESTRICT at two direct course edges and
-- at every coupon-provenance edge. That made a legitimate platform_courses
-- delete fail as soon as the course had generated or redeemed coupons.
--
-- Cascade the direct course-owned rows. Keep direct coupon deletion protected,
-- but defer those provenance checks until transaction end so the existing
-- course/enrollment/entitlement cascades can complete first.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table public.platform_course_coupons
  drop constraint platform_course_coupons_course_id_fkey,
  add constraint platform_course_coupons_course_id_fkey
    foreign key (course_id)
    references public.platform_courses(id)
    on delete cascade;

alter table public.platform_course_coupon_redemptions
  drop constraint platform_course_coupon_redemptions_course_id_fkey,
  add constraint platform_course_coupon_redemptions_course_id_fkey
    foreign key (course_id)
    references public.platform_courses(id)
    on delete cascade,
  drop constraint platform_course_coupon_redemptions_coupon_id_fkey,
  add constraint platform_course_coupon_redemptions_coupon_id_fkey
    foreign key (coupon_id)
    references public.platform_course_coupons(id)
    on delete no action
    deferrable initially deferred;

alter table public.platform_course_module_entitlements
  drop constraint platform_course_module_entitlements_source_coupon_id_fkey,
  add constraint platform_course_module_entitlements_source_coupon_id_fkey
    foreign key (source_coupon_id)
    references public.platform_course_coupons(id)
    on delete no action
    deferrable initially deferred;

alter table public.platform_course_enrollments
  drop constraint platform_course_enrollments_source_coupon_id_fkey,
  add constraint platform_course_enrollments_source_coupon_id_fkey
    foreign key (source_coupon_id)
    references public.platform_course_coupons(id)
    on delete no action
    deferrable initially deferred;

-- PostgreSQL does not create indexes for foreign-key columns. These two
-- partial indexes keep deferred provenance checks and course cascades bounded
-- to the rows that actually came from coupons.
create index if not exists idx_platform_course_module_entitlements_source_coupon
  on public.platform_course_module_entitlements(source_coupon_id)
  where source_coupon_id is not null;

create index if not exists idx_platform_course_enrollments_source_coupon
  on public.platform_course_enrollments(source_coupon_id)
  where source_coupon_id is not null;

commit;
