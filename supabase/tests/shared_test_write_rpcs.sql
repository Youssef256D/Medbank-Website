-- Checks the shared-test write rules (save_test_responses,
-- save_test_block_progress and the two guard triggers) on a THROWAWAY LOCAL
-- Postgres, never the hosted project: it builds a minimal copy of the test
-- tables (owner-only RLS, auth.uid() read from the test.uid setting), then
-- applies the two migrations from this repo.
--
--   createdb shared_test_check
--   psql -d shared_test_check -f supabase/tests/shared_test_write_rpcs.sql | grep -E 'PASS|FAIL'
--   dropdb shared_test_check
--
-- Every line should read PASS.

\set ON_ERROR_STOP 1
\set QUIET 1
do $$ begin create role anon; exception when duplicate_object then null; end $$; do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
create schema auth; create schema private;
grant usage on schema private, auth to authenticated;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
grant execute on function auth.uid() to authenticated;
create type public.app_block_mode as enum ('tutor','timed');
create type public.app_block_source as enum ('all','unused','incorrect','flagged');
create type public.app_block_status as enum ('in_progress','completed','suspended');
create function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create table public.test_blocks (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, course_id uuid,
  mode app_block_mode not null, source app_block_source not null, status app_block_status not null default 'in_progress',
  question_count int not null check (question_count > 0), duration_minutes int, time_remaining_sec int,
  current_index int not null default 0, elapsed_seconds int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), completed_at timestamptz, external_id text unique);
create trigger trg_test_blocks_updated_at before update on public.test_blocks for each row execute function set_updated_at();
create table public.test_block_items (block_id uuid references test_blocks(id) on delete cascade, position int not null, question_id uuid not null, primary key (block_id, question_id));
create table public.test_responses (block_id uuid not null, question_id uuid not null,
  selected_choice_labels text[] not null default '{}', flagged boolean not null default false, notes text,
  submitted boolean not null default false, answered_at timestamptz, primary key (block_id, question_id),
  foreign key (block_id, question_id) references test_block_items(block_id, question_id) on delete cascade);
alter table test_blocks enable row level security; alter table test_responses enable row level security; alter table test_block_items enable row level security;
create policy b_all on test_blocks for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy i_all on test_block_items for all to authenticated using (exists (select 1 from test_blocks b where b.id = block_id and b.user_id = auth.uid()));
create policy r_all on test_responses for all to authenticated using (exists (select 1 from test_blocks b where b.id = block_id and b.user_id = auth.uid())) with check (exists (select 1 from test_blocks b where b.id = block_id and b.user_id = auth.uid()));
grant select, insert, update on test_blocks, test_block_items, test_responses to authenticated;

\ir ../migrations/20261025200000_protect_test_response_answers.sql
\ir ../migrations/20261027130000_shared_test_write_rpcs.sql

\pset format unaligned
\pset tuples_only on
insert into test_blocks (id,user_id,mode,source,question_count,time_remaining_sec,elapsed_seconds) values
 ('b0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','timed','all',3,600,100),
 ('b0000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000002','tutor','all',1,null,0);
insert into test_block_items values
 ('b0000000-0000-4000-8000-000000000001',1,'c0000000-0000-4000-8000-000000000001'),
 ('b0000000-0000-4000-8000-000000000001',2,'c0000000-0000-4000-8000-000000000002'),
 ('b0000000-0000-4000-8000-000000000001',3,'c0000000-0000-4000-8000-000000000003'),
 ('b0000000-0000-4000-8000-000000000002',1,'c0000000-0000-4000-8000-000000000001');
create function pg_temp.chk(name text, ok boolean) returns text language sql as $$ select case when ok then 'PASS ' else 'FAIL ' end || name $$;
set role authenticated;
select set_config('test.uid','a0000000-0000-4000-8000-000000000001',false);
\set B '''b0000000-0000-4000-8000-000000000001'''
\set Q1 '''c0000000-0000-4000-8000-000000000001'''
\set Q2 '''c0000000-0000-4000-8000-000000000002'''
-- insert pick (normalised, deduped, junk dropped)
select pg_temp.chk('insert pick', selected_choice_labels = '{B,A}' and not submitted) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["b"," A","b","Z"],"submitted":false}]');
-- CAS miss: expected differs from stored -> unchanged
select pg_temp.chk('cas miss', selected_choice_labels = '{B,A}') from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["C"],"expected":["D"]}]');
-- expected [] on a stored answer (website never-synced) -> unchanged
select pg_temp.chk('insert-only', selected_choice_labels = '{B,A}') from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["C"],"expected":[]}]');
-- CAS hit
select pg_temp.chk('cas hit', selected_choice_labels = '{C}') from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["C"],"expected":["B","A"]}]');
-- no expected: overwrite unsolved
select pg_temp.chk('overwrite', selected_choice_labels = '{D}') from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["D"]}]');
-- empty selection leaves answer, flag-only keeps answer
select pg_temp.chk('empty keeps', selected_choice_labels = '{D}' and flagged) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":[],"submitted":true,"flagged":true}]');
select pg_temp.chk('notes only', selected_choice_labels = '{D}' and flagged and notes = 'n1') from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","notes":"n1"}]');
-- submitted answer skips the compare-and-set (Q3 holds an unsubmitted E)
select 1 from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000003","selected":["E"]}]');
select pg_temp.chk('submit beats cas', selected_choice_labels = '{D}' and submitted) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000003","selected":["D"],"submitted":true,"expected":["A"]}]');
-- submit
select pg_temp.chk('submit', selected_choice_labels = '{D}' and submitted and flagged) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["D"],"submitted":true,"expected":["D"]}]');
-- solved stays solved via RPC
select pg_temp.chk('solved rpc', selected_choice_labels = '{D}' and submitted) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000001","selected":["A"],"submitted":false}]');
-- solved stays solved via raw table upsert (old app build)
insert into test_responses (block_id,question_id,selected_choice_labels,submitted) values (:B,:Q1,'{A}',false) on conflict (block_id,question_id) do update set selected_choice_labels=excluded.selected_choice_labels, submitted=excluded.submitted;
select pg_temp.chk('solved trigger', selected_choice_labels = '{D}' and submitted) from test_responses where block_id=:B and question_id=:Q1;
-- not an item -> skipped; batch returns only Q2
select pg_temp.chk('non-item skipped', count(*) = 1) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000009","selected":["A"]},{"question_id":"c0000000-0000-4000-8000-000000000002","flagged":true}]');
select pg_temp.chk('flag-only new row', selected_choice_labels = '{}' and flagged and not submitted) from test_responses where block_id=:B and question_id=:Q2;
-- submitted with no selection never stored
select pg_temp.chk('no empty submitted', not submitted) from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000002","submitted":true}]');
-- progress: monotonic clock, no-op leaves updated_at
select updated_at as before_noop from test_blocks where id=:B \gset
select pg_temp.chk('noop progress', updated_at = :'before_noop') from save_test_block_progress(:B, null, 50, 900);
select pg_temp.chk('clock monotonic', elapsed_seconds = 100 and time_remaining_sec = 600) from save_test_block_progress(:B, 1, 50, 900);
select pg_temp.chk('clock moves', elapsed_seconds = 130 and time_remaining_sec = 570 and current_index = 1) from save_test_block_progress(:B, 1, 130, 570);
select pg_temp.chk('suspend', status = 'suspended') from save_test_block_progress(:B, null, null, null, 'suspended');
select pg_temp.chk('resume', status = 'in_progress') from save_test_block_progress(:B, null, null, null, 'in_progress');
select pg_temp.chk('complete', status = 'completed' and completed_at = '2026-10-27 10:00+00') from save_test_block_progress(:B, null, null, null, 'completed', '2026-10-27 10:00+00');
select pg_temp.chk('completed final', status = 'completed' and completed_at = '2026-10-27 10:00+00' and elapsed_seconds = 130) from save_test_block_progress(:B, 0, 999, 0, 'in_progress', now());
update test_blocks set status = 'in_progress', completed_at = null where id = :B;
select pg_temp.chk('completed trigger', status = 'completed' and completed_at is not null) from test_blocks where id = :B;
-- completed block: answers frozen, notes still save
select pg_temp.chk('frozen answers', selected_choice_labels = '{}' and notes = 'late') from save_test_responses(:B, '[{"question_id":"c0000000-0000-4000-8000-000000000002","selected":["B"],"notes":"late"}]');
-- other user's block: not found
select set_config('test.uid','a0000000-0000-4000-8000-000000000002',false);
do $$ begin perform save_test_responses('b0000000-0000-4000-8000-000000000001','[]'); raise exception 'FAIL other user'; exception when sqlstate 'P0002' then raise notice 'PASS other user not found'; end $$;
do $$ begin perform save_test_block_progress('b0000000-0000-4000-8000-000000000001', 1); raise exception 'FAIL other user progress'; exception when sqlstate 'P0002' then raise notice 'PASS other user progress not found'; end $$;
select set_config('test.uid','',false);
do $$ begin perform save_test_responses('b0000000-0000-4000-8000-000000000001','[]'); raise exception 'FAIL anon'; exception when sqlstate '42501' then raise notice 'PASS no uid'; end $$;
