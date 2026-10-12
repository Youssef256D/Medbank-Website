-- Permanently delete MCQ questions (topic delete, "Delete all topics", single
-- question delete). Until now the site only archived them (status='archived').
--
-- test_block_items.question_id is ON DELETE RESTRICT, so a question that any
-- student has used cannot be deleted directly; and deleting test_block_items
-- from the browser needs the 'people' admin area. This SECURITY DEFINER RPC
-- does the whole thing in one transaction, gated on the same
-- 'mcq.questions_delete' action the questions trigger already checks:
--   1. delete the questions' rows in students' tests (test_responses cascade),
--   2. delete test blocks left with no questions, fix question_count /
--      current_index on the rest,
--   3. delete the questions (question_choices cascade).
-- Returns the number of questions deleted.

create or replace function public.admin_delete_questions(target_question_ids uuid[])
returns integer
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  ids uuid[];
  affected_blocks uuid[];
  deleted_count integer := 0;
begin
  if not private.is_admin_user() or not private.admin_can('mcq.questions_delete') then
    raise exception 'Your admin account is not allowed to delete questions.' using errcode = '42501';
  end if;

  select coalesce(array_agg(distinct id), '{}') into ids
  from unnest(coalesce(target_question_ids, '{}')) as id
  where id is not null;
  if cardinality(ids) = 0 then
    return 0;
  end if;

  select coalesce(array_agg(distinct item.block_id), '{}') into affected_blocks
  from public.test_block_items as item
  where item.question_id = any(ids);

  delete from public.test_block_items as item
  where item.question_id = any(ids);

  if cardinality(affected_blocks) > 0 then
    delete from public.test_blocks as block
    where block.id = any(affected_blocks)
      and not exists (select 1 from public.test_block_items as item where item.block_id = block.id);

    update public.test_blocks as block
    set question_count = remaining.item_count,
        current_index = least(coalesce(block.current_index, 0), greatest(remaining.item_count - 1, 0))
    from (
      select item.block_id, count(*)::integer as item_count
      from public.test_block_items as item
      where item.block_id = any(affected_blocks)
      group by item.block_id
    ) as remaining
    where block.id = remaining.block_id;
  end if;

  delete from public.questions as question
  where question.id = any(ids);
  get diagnostics deleted_count = row_count;

  return deleted_count;
end;
$function$;

revoke all on function public.admin_delete_questions(uuid[]) from public, anon;
grant execute on function public.admin_delete_questions(uuid[]) to authenticated;

notify pgrst, 'reload schema';
