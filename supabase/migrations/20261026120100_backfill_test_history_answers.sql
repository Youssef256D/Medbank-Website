-- Backfill for 20261026120000_admin_student_results: copies the answers of
-- every finished test saved before the trigger existed. Skips tests that
-- already have rows, so running it again is cheap.

do $$
declare
  v_id uuid;
begin
  for v_id in
    select h.id
    from public.test_history_entries h
    where not exists (select 1 from public.test_history_answers a where a.history_id = h.id)
    order by h.created_at
  loop
    perform private.refresh_test_history_answers(v_id);
  end loop;
end;
$$;
