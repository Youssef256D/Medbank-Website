begin;

-- Follow-up to 20260809114410. That migration made course deletion cascade
-- through coupons, but missed platform_course_coupon_modules.module_id, which
-- was still ON DELETE RESTRICT against platform_course_modules. RESTRICT is
-- checked immediately, so deleting a course whose coupons grant module access
-- failed as soon as the cascade reached its modules -- before the parallel
-- coupons -> coupon_modules cascade could remove the referencing rows.
--
-- NO ACTION DEFERRABLE INITIALLY DEFERRED lets both cascades finish before the
-- check runs at transaction end. Deleting a module directly while a coupon
-- still references it is still rejected, matching the other coupon edges.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table public.platform_course_coupon_modules
  drop constraint platform_course_coupon_modules_module_id_fkey,
  add constraint platform_course_coupon_modules_module_id_fkey
    foreign key (module_id)
    references public.platform_course_modules(id)
    on delete no action
    deferrable initially deferred;

commit;
