# IBF answer review (2026-10-18)

**Course:** Introduction to Body Function (IBF 102), Year 1 Semester 1. 924 questions in total: 852 published, 17 draft, 55 archived.
**Checked against:** the two IBF handouts in `Desktop/Medbank Digitalized Questions/1st year/1st semster/IBF/Handouts/`:
- `xxxIBF Handout word file 2024-2025 (1).pdf` (biochemistry chapters I–V, plus the ANS summary on pages 29–34)
- `ANS lectures power point 24-25.pdf` (physiology, autonomic nervous system)

**Status (2026-10-19): sections 1–3 are applied to the live database.** They were run from `reports/ibf-answer-fix-2026-10-18.sql` in the Supabase SQL editor and checked afterwards. 850 questions are now published, and each has exactly one correct answer. The old values are in `reports/ibf-answer-fix-backup-2026-10-18.json`. Section 4: the 17 checked drafts were published on 2026-10-19 (`reports/ibf-publish-drafts-2026-10-19.sql`), so 867 questions are now published.

All 852 published questions were read one by one. **About 835 are right by the handout.** The problems are below.

---

## 1. Wrong answer marked (3 questions)

| Topic | Question | Now | Should be | Why |
|---|---|---|---|---|
| Acids, Bases, pH & Buffers | The cation in plasma buffers is | B) Potassium | **A) Sodium** | Handout p.2 table: plasma buffers contain sodium and RBC buffers contain potassium. The question's own explanation already says sodium. |
| Amino Acids | Lysine is a (Basic ketogenic / Ketogenic and glucogenic / …) | A) Basic ketogenic | **B) Ketogenic and glucogenic** | Handout p.6: "leucine is the only pure ketogenic amino acid" and lysine is listed with the mixed ones. |
| Amino Acids | The two amino acids that are purely ketogenic are | A) Lysine and leucine | Reword the question to **"The two amino acids that are both ketogenic and glucogenic (mixed) are"**, with answer **B) Lysine and isoleucine** | By the handout only one amino acid (leucine) is purely ketogenic, so the question has no right answer as written. With the new wording, the answer choices stay the same. |

**Note on lysine:** Lippincott and most US textbooks call lysine *purely* ketogenic, alongside leucine. Your handout says it is mixed. I went with the handout because the exam follows it. If you would rather follow Lippincott, leave rows 2 and 3 alone.

## 2. Two answers are right by the handout (5 questions)

The marked answer is right, but by the handout a second option is also right. The fix is to replace the extra right option and keep the same answer.

| Topic | Question | Marked | Second right option | Change it to |
|---|---|---|---|---|
| Amino Acids | Lysine, all correct EXCEPT | C) It is a glucogenic amino acid | By the handout lysine *is* glucogenic (mixed), so C is not false | C → **"It is a purely ketogenic amino acid"** (false by the handout) |
| Lipid Classification | All are essential fatty acids except | D) Palmitic acid | C) Arachidonic acid: the handout lists only linoleic and linolenic as essential | C → **"None of them"** |
| Homopolysaccharides | All are non-reducing carbohydrates except | A) Dextrins | Handout p.22: "starch and dextrins … non reducing", so no option is reducing | A → **"Maltose"** (keep it as the answer) |
| Minerals | All are functions of sodium except | C) Generation of nerve impulses | Not in the handout's sodium list, but sodium really is essential for nerve impulses, so this teaches a false fact | C → **"Storage of insulin"** (that is zinc) |
| Noradrenaline & Adrenergic Receptors | Mono amine oxidase is important for | D) Inactivation of noradrenaline in the neurons | C) "…in the liver" is also true. ANS slides p.27 say MAO is in nerve endings, kidney and liver | C → **"Inactivation of acetylcholine"** |

The explanations of these questions would be rewritten to match.

## 3. Broken questions

- **Two published questions have no answer choices at all**, and neither belongs in IBF. Students can see them but can't answer them. The fix is to set both to draft:
  - "ABG: pH 7.28, pCO2 30 mmHg, HCO3- 14 mEq/L. What is the primary disorder?"
  - "First-line treatment for tense ascites due to cirrhosis includes sodium restriction and:" (a clinical medicine question)
- **Leftover text from the PDF copy** (no answer changes):
  - "P a g e 4", "P a g e 10" … "P a g e 31" stuck to the end of an option in 17 questions, and in one stem.
  - "Key answers" stuck to an option in the liver-failure oedema question.
  - The answer of "Which one is the least polar bile acid?" reads "Lithocholic. 144. A 5 years old male came to a hospital…": a whole other question pasted into the option.
  - "creatine sulfate" should be "keratan sulfate" (Aggrecan question, in the correct answer).
  - "exce 2" should be "except"; "parasyinpathetic" should be "parasympathetic"; "II! (3)" and "XI! (12)" should be "III (3)" and "XII (12)"; "nucleus9" should be "nucleus".
  - "The mother compound of ketoses is": the answer reads "Dihydroxyacetone phosphate", but the handout says dihydroxyacetone.

## 4. The 17 draft questions

These were held back from students when the course was imported (see `IBF_review_flags.txt`). I checked all 17 against the handout and **every one is right**: zinc → carbonic anhydrase, α/β-glucose → anomers, moderate oxidation → glucuronic acid (handout p.20 says exactly this), muramic acid → lactic acid + glucosamine, glucocorticoids except → "stimulate protein and fat synthesis", and so on. They can be published if you want them visible.

## 5. Right by the handout, but worth knowing

No change suggested for these. They are listed in case a student asks.

- **Lysine as an essential amino acid:** the handout's list of essential amino acids leaves lysine out. Every textbook includes it, so the questions that treat it as essential are kept.
- **Sympathetic outflow to the head and neck:** the slides say T1–T2. Some textbooks say T1–T3.
- **Chondroitin sulfate:** the handout's text and its table disagree on whether it contains 4-sulfate or 6-sulfate. The MedBank question is fine either way.
- **Heparin:** the handout says it "inhibits factors II, VII, IX and X". The MedBank question's answer, "activates antithrombin III", is the textbook mechanism behind that. Both are right.
