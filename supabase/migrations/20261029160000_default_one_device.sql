-- One device per student by default (owner decision 2026-10-29, replacing
-- "no limit unless an admin sets one"). An admin raises or removes it on
-- Site access → Device limit, or per university, organization or student.
alter table public.device_access_settings
  alter column limit_enabled set default true,
  alter column device_limit set default 1;

update public.device_access_settings
set limit_enabled = true,
    device_limit = 1;
