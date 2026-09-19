begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table public.platform_course_coupon_modules
  drop constraint platform_course_coupon_modules_module_id_fkey,
  add constraint platform_course_coupon_modules_module_id_fkey
    foreign key (module_id)
    references public.platform_course_modules(id)
    on delete restrict;

commit;
