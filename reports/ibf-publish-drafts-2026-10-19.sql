-- Publish the 17 IBF draft questions that were checked against the handout
-- (see reports/ibf-answer-review-2026-10-18.md, section 4).
-- Paste all of it into the Supabase SQL editor (project fzjzjzdamehxbgikiskt) and press Run.
-- Undo: run the same update with status='draft'.

update questions set status='published'
where course_id='34f9cf8b-9145-4fad-ab97-8a6a9da8c96c' and status='draft' and id in (
  '016bc20e-10c6-4963-a22e-a463e8ec52dc', -- hydrolytic products of muramic acid
  '027c2f5c-a64b-4e78-a729-f758946c70e9', -- norepinephrine contracts smooth muscle in
  '09eba0c8-daf0-41aa-b5c6-233e971ec094', -- fatty acids (even number of carbons)
  '0ac50475-94da-4dad-ad96-41413b024321', -- cutting left paravertebral ganglia
  '15794a9d-4f13-497a-975f-f16ed9ebb52b', -- NOT a feature of brittle bone disease
  '201fffee-7292-42b3-a451-572f3288677c', -- moderate oxidation of glucose
  '2898aad0-14dd-499a-bda6-5f96aa9966e4', -- glucocorticoids except
  '29fe98fb-a889-41a4-aba8-1f07358f52c0', -- NOT a feature of Marfan syndrome
  '2f4bd74b-28a7-496a-8123-8947e44f5bee', -- protein containing zinc
  '65d06f27-194a-4e5a-81ee-0bf141470b77', -- alpha and beta glucose
  '71fdbfd1-a1ee-465e-9399-721b33e2b820', -- parasympathetic supply to the pelvis
  '84321e62-b36f-48d2-8eb9-d4ba69831d29', -- example of epimers
  '95234810-d523-4f26-9453-dfd345921392', -- vagus stimulation does not produce
  '9907cb4a-317c-439d-9eb5-6543db2a03b6', -- thromboxanes cause
  'bd1e13bc-065b-43cf-a439-2e49996b6440', -- catecholamines on alpha receptors
  'da341282-e1e5-4730-b829-bb35e0c31c7c', -- sympathetic fibers to head and neck
  'ebff85f9-d0e6-4dc3-98e7-c89455ebe445'  -- atropine on intestine
);

-- Check: should return  867 | 2
select
  (select count(*) from questions where course_id='34f9cf8b-9145-4fad-ab97-8a6a9da8c96c' and status='published') as published,
  (select count(*) from questions where course_id='34f9cf8b-9145-4fad-ab97-8a6a9da8c96c' and status='draft') as drafts_left;
