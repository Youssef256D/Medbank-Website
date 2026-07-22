-- Optional context for notification destinations. MCQ filters use their
-- canonical display names because that is what the static SPA stores in its
-- curriculum catalog; Video Courses use the platform course UUID.
alter table public.notifications
  add column if not exists target_mcq_subject text,
  add column if not exists target_mcq_topic text,
  add column if not exists target_video_course_id uuid;

alter table public.notifications
  drop constraint if exists notifications_target_video_course_id_fkey,
  add constraint notifications_target_video_course_id_fkey
    foreign key (target_video_course_id)
    references public.platform_courses(id)
    on delete set null;

alter table public.notifications
  drop constraint if exists notifications_target_context_check,
  add constraint notifications_target_context_check check (
    (target_mcq_topic is null or target_mcq_subject is not null)
    and (target_mcq_subject is null or target_route = 'create-test')
    and (target_mcq_topic is null or target_route = 'create-test')
    and (target_video_course_id is null or target_route = 'video-courses')
    and not (
      (target_mcq_subject is not null or target_mcq_topic is not null)
      and target_video_course_id is not null
    )
  );

create index if not exists notifications_target_video_course_id_idx
  on public.notifications (target_video_course_id)
  where target_video_course_id is not null;

comment on column public.notifications.target_mcq_subject is
  'Optional canonical MCQ Subject name preselected when target_route is create-test.';
comment on column public.notifications.target_mcq_topic is
  'Optional MCQ topic name preselected within target_mcq_subject.';
comment on column public.notifications.target_video_course_id is
  'Optional Video Course opened directly when target_route is video-courses.';
