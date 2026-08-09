begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

drop index if exists public.idx_platform_course_module_entitlements_source_coupon;
drop index if exists public.idx_platform_course_enrollments_source_coupon;

alter table public.platform_course_enrollments
  drop constraint platform_course_enrollments_source_coupon_id_fkey,
  add constraint platform_course_enrollments_source_coupon_id_fkey
    foreign key (source_coupon_id)
    references public.platform_course_coupons(id)
    on delete restrict;

alter table public.platform_course_module_entitlements
  drop constraint platform_course_module_entitlements_source_coupon_id_fkey,
  add constraint platform_course_module_entitlements_source_coupon_id_fkey
    foreign key (source_coupon_id)
    references public.platform_course_coupons(id)
    on delete restrict;

alter table public.platform_course_coupon_redemptions
  drop constraint platform_course_coupon_redemptions_coupon_id_fkey,
  add constraint platform_course_coupon_redemptions_coupon_id_fkey
    foreign key (coupon_id)
    references public.platform_course_coupons(id)
    on delete restrict,
  drop constraint platform_course_coupon_redemptions_course_id_fkey,
  add constraint platform_course_coupon_redemptions_course_id_fkey
    foreign key (course_id)
    references public.platform_courses(id)
    on delete restrict;

alter table public.platform_course_coupons
  drop constraint platform_course_coupons_course_id_fkey,
  add constraint platform_course_coupons_course_id_fkey
    foreign key (course_id)
    references public.platform_courses(id)
    on delete restrict;

commit;
