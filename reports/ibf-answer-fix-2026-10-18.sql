-- IBF answer fixes (see reports/ibf-answer-review-2026-10-18.md).
-- Old values: reports/ibf-answer-fix-backup-2026-10-18.json
-- Paste all of it into the Supabase SQL editor (project fzjzjzdamehxbgikiskt) and press Run.
-- The editor runs the whole script as one transaction: if any line fails, nothing changes.

-- 1. Wrong answer marked
update question_choices set is_correct = (id='8aa62079-9964-49ff-a967-1f35d02882fb') where question_id='a32df4c3-67e5-4ffd-97a7-86583946375f';
update question_choices set is_correct = (id='36e6b770-1cf1-49de-8ef7-ef19bba02bce') where question_id='b98fa0e9-6f57-48b9-86f6-caa99b7978d2';
update questions set explanation='Lysine is a basic amino acid (two amino groups). The IBF handout lists it with the mixed ketogenic and glucogenic amino acids; leucine is the only purely ketogenic one.' where id='b98fa0e9-6f57-48b9-86f6-caa99b7978d2';
update question_choices set is_correct = (id='87087258-0003-4334-9e85-677b364d3773') where question_id='99846d48-fca7-4af8-ac27-f50470825e78';
update questions set stem='The two amino acids that are both ketogenic and glucogenic (mixed) are', explanation='Handout: the mixed ketogenic and glucogenic amino acids are phenylalanine, tyrosine, tryptophan, isoleucine and lysine. Leucine is the only purely ketogenic amino acid, and valine is glucogenic.' where id='99846d48-fca7-4af8-ac27-f50470825e78';

-- 2. Two right answers by the handout: replace the extra right option
update question_choices set choice_text='It is a purely ketogenic amino acid' where id='c90e6e7e-a56b-468a-86ac-f5be0284105c';
update questions set explanation='Handout: leucine is the only purely ketogenic amino acid; lysine is mixed (ketogenic and glucogenic). Lysine has two amino groups, is essential and is part of collagen.' where id='59c8105c-c195-4c31-a2cf-ca629a6dce0e';
update question_choices set choice_text='None of them' where id='602bee54-dcc0-4dd8-89d8-483d1d6df098';
update questions set explanation='Handout: the essential fatty acids are linoleic and linolenic acids. Palmitic acid is saturated and non-essential.' where id='83a83a96-1c08-4863-94dd-b5c50ed4e8fb';
update question_choices set choice_text='Maltose' where id='6adecbd5-34aa-422f-b938-85abf0f963e3';
update questions set explanation='Maltose has a free reducing group. Starch (amylose and amylopectin) and sucrose are non-reducing (handout).' where id='ae37bef1-fda2-42dc-91eb-62a16503707c';
update question_choices set choice_text='Storage of insulin' where id='f83bf550-77fd-4dfb-bc89-8d4552025069';
update questions set explanation='Handout: sodium is present in bones and extracellular fluid and regulates acid-base balance and osmotic pressure. Storage of insulin needs zinc.' where id='5dc84f43-ae5e-448f-b641-6111b01e4706';
update question_choices set choice_text='Inactivation of acetylcholine' where id='9103eddf-dc28-4e16-8d42-500c1a21b287';
update questions set explanation='MAO destroys noradrenaline in nerve endings (also in kidney and liver). Acetylcholine is broken down by acetylcholinesterase.' where id='d10ca35c-7a5e-46b2-939d-2574f8760b63';
update question_choices set choice_text='Dihydroxyacetone' where id='8d02da28-5fbe-4d3e-ae18-749da086cf2f';

-- 3. Leftover PDF text
update question_choices c set choice_text = btrim(regexp_replace(c.choice_text, '\s*P a g e \d+\s*$', ''))
  from questions q where q.id=c.question_id and q.course_id='34f9cf8b-9145-4fad-ab97-8a6a9da8c96c' and c.choice_text ~ 'P a g e \d+\s*$';
update questions set stem='The number of asymmetric carbons in glucose is ……' where id='34a568fc-941e-4f5d-ac5b-6151eac45f98';
update questions set stem='The sympathetic nervous system does all of the following except' where id='8f77dbfc-cb5c-45fe-bfa8-6ecbb8c77299';
update questions set stem='The following cranial nerve carries parasympathetic nerve fibers' where id='f06934ba-9ff2-4c75-9c67-b71e7efd0312';
update question_choices set choice_text='Cranial nerve number III (3)' where id='307777e3-6a43-40d5-a77a-6dddd7cee013';
update question_choices set choice_text='Cranial nerve number XII (12)' where id='f7bc0984-a572-45b4-a175-f23bb6c6ec62';
update question_choices set choice_text='Increased rate of formation than rate of reabsorption of interstitial fluid' where id='9c417d46-85f5-4bd0-a7ec-2ffb76e88193';
update question_choices set choice_text='Lithocholic acid' where id='cbc39e03-5441-46cb-87a8-984f5f5ba36d';
update question_choices set choice_text='It contains hyaluronic acid, keratan sulfate and chondroitin sulfate' where id='d4a92621-b951-45cb-8034-d106bc00d1a7';
update question_choices set choice_text='Arise from inferior salivary nucleus' where id='d3785dcc-2d21-4476-9ec1-e6d448fcade6';

-- 4. Published questions with no answer choices -> draft
update questions set status='draft' where id in ('905e0aa7-53c4-4259-a902-87c5b8f11ebb','98368314-9ba8-4872-ab55-ef6c270a5b10');

-- Check: should return  A | B | B | 0
select
  (select choice_label from question_choices where question_id='a32df4c3-67e5-4ffd-97a7-86583946375f' and is_correct) as plasma_cation,
  (select choice_label from question_choices where question_id='b98fa0e9-6f57-48b9-86f6-caa99b7978d2' and is_correct) as lysine,
  (select choice_label from question_choices where question_id='99846d48-fca7-4af8-ac27-f50470825e78' and is_correct) as mixed_pair,
  (select count(*) from question_choices c join questions q on q.id=c.question_id
     where q.course_id='34f9cf8b-9145-4fad-ab97-8a6a9da8c96c' and c.choice_text ~ 'P a g e') as page_junk_left;
