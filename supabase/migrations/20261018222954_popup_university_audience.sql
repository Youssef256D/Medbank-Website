-- Pop-ups may target a university.
--
-- Next to the organization audience (20261009210200), a pop-up can now be
-- limited to the students of one university (`profiles.university_id`).
-- The two audiences combine: a pop-up for organization X and university Y
-- reaches only members of X who study at Y.
--
-- Same shape as the organization audience: `university_audience` says
-- whether a university is required, `target_university_id` names it. When
-- that university is deleted the id is set null and the pop-up reaches
-- nobody, rather than widening to every university.
--
-- Additive only: existing rows default to 'everyone', and apps built before
-- this ignore the extra columns returned by get_my_active_popups().

alter table public.app_popups
  add column university_audience text not null default 'everyone'
    check (university_audience in ('everyone', 'university')),
  add column target_university_id uuid
    references public.universities(id) on delete set null;

alter table public.app_popups
  add constraint app_popups_target_university_pairing
    check (target_university_id is null or university_audience = 'university');

create index app_popups_target_university_idx
  on public.app_popups (target_university_id);

comment on column public.app_popups.university_audience is
  'everyone; university: accounts whose profiles.university_id is target_university_id.';

CREATE OR REPLACE FUNCTION public.get_my_active_popups()
 RETURNS SETOF public.app_popups
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select p.*
  from public.app_popups p
  left join public.app_popup_views v
    on v.popup_id = p.id and v.user_id = auth.uid()
  cross join lateral (
    select
      role,
      academic_year,
      university_id,
      exists (
        select 1 from public.organization_members om where om.user_id = auth.uid()
      ) as in_any_organization
    from public.profiles
    where id = auth.uid()
  ) me
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at is null or p.ends_at > now())
    -- profiles.role is the app_user_role enum, not text, so the cast is
    -- load-bearing: without it Postgres refuses the comparison outright
    -- (42883) and the whole function fails to create.
    and (p.audience_role = 'all' or p.audience_role = me.role::text)
    and (
      p.audience_academic_year is null
      or p.audience_academic_year = me.academic_year
    )
    and (
      case p.organization_audience
        when 'everyone' then true
        when 'no_organization' then not me.in_any_organization
        when 'organization' then
          p.target_organization_id is not null
          and exists (
            select 1 from public.organization_members om
            where om.user_id = auth.uid()
              and om.organization_id = p.target_organization_id
          )
        else false
      end
    )
    and (
      case p.university_audience
        when 'everyone' then true
        when 'university' then
          p.target_university_id is not null
          and me.university_id = p.target_university_id
        else false
      end
    )
    -- A pop-up about a video course reaches only students who can open it.
    -- CASE, so a malformed id is never cast.
    and (
      case
        when p.target_video_course_id is null then true
        when p.target_video_course_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then private.user_in_video_course_audience(auth.uid(), p.target_video_course_id::uuid)
        else false
      end
    )
    and (
      case p.display_rule
        when 'every_launch' then true
        when 'daily' then
          v.last_seen_at is null
          or v.last_seen_at < date_trunc('day', now())
        else v.seen_count is null or v.seen_count = 0
      end
    )
  order by p.priority desc, p.created_at desc;
$function$;

-- CREATE OR REPLACE keeps the existing grants (authenticated only, see
-- 20260910130000); restate them so this file is correct on its own.
revoke execute on function public.get_my_active_popups() from public, anon;
grant execute on function public.get_my_active_popups() to authenticated;
