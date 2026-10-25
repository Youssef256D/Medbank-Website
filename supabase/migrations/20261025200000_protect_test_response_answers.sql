-- Never let a write clear an answer that was already picked.
--
-- On 2026-10-25 an early version of the website's shared-tests sync sent
-- test_responses rows with an empty selection and submitted = true, which
-- wiped answers students had given in the app and locked those questions
-- (both clients refuse to change a submitted question). Browser tabs still
-- running that version keep sending such rows until they reload, so the rule
-- lives in the database where every client goes through it:
--   * an update with an empty selection keeps the previous selection and
--     submitted flag (flag and notes still update);
--   * a row with no selection is never stored as submitted.
-- Neither client ever clears a selection on purpose: the app's selectAnswer
-- always sets one label, and the website's submit button refuses an empty one.

create or replace function private.protect_test_response_answer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
     and coalesce(cardinality(new.selected_choice_labels), 0) = 0
     and coalesce(cardinality(old.selected_choice_labels), 0) > 0 then
    new.selected_choice_labels := old.selected_choice_labels;
    new.submitted := old.submitted;
    new.answered_at := old.answered_at;
  end if;

  if coalesce(cardinality(new.selected_choice_labels), 0) = 0 then
    new.submitted := false;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_test_response_answer on public.test_responses;
create trigger trg_protect_test_response_answer
  before insert or update on public.test_responses
  for each row execute function private.protect_test_response_answer();

-- One-time repair: unlock questions already stored as submitted with no
-- answer in unfinished tests. Finished tests are left as they are.
update public.test_responses r
set submitted = false
from public.test_blocks b
where b.id = r.block_id
  and b.status in ('in_progress', 'suspended')
  and r.submitted
  and coalesce(cardinality(r.selected_choice_labels), 0) = 0;
