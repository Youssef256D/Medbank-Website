-- Remove the Hermes AI admin assistant (owner decision, 2026-10-19).
--
-- Drops the control plane created by 20260525172940_add_admin_agent_control_plane
-- and 20260525181556_extend_admin_agents_full_access. Last agent activity was
-- 2026-06-11. The owner chose to delete the 4,103 action-log rows with no
-- backup. The website page, the admin-agent-tool Edge Function and the
-- app's Logs page (which only listed Hermes actions) are removed alongside.
--
-- Their policies, indexes and updated_at triggers go with the tables. The
-- shared public.set_updated_at() function is used elsewhere and stays.

begin;

-- Children first: approval requests point at the action log, and every
-- table points at admin_agents.
drop table if exists public.admin_agent_approval_requests;
drop table if exists public.admin_agent_action_log;
drop table if exists public.admin_agent_permissions;
drop table if exists public.admin_agents;

commit;
