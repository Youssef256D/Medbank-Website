'use strict';

// Previous tests older than 30 days are slimmed on the server: each question
// snapshot keeps ids, names, choice labels and `correct`, but loses its stem,
// choice text and explanation. Review must take the text from the live bank,
// keep the snapshot's answer key (so the score never changes), show a
// labelled placeholder for a question no longer in the bank, and never write a
// full snapshot back over a slim one.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const from = mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', from);
  assert.ok(from >= 0 && end > from, `main.js function moved: ${name}`);
  return mainSource.slice(from, end) + '\n}\n';
};
const topLevelLine = (prefix) => {
  const from = mainSource.indexOf(`\n${prefix}`);
  assert.ok(from >= 0, `main.js declaration moved: ${prefix}`);
  return mainSource.slice(from, mainSource.indexOf('\n', from + 1)) + '\n';
};

const DB_ID = '33333333-3333-4333-8333-333333333333';
const GONE_ID = '44444444-4444-4444-8444-444444444444';

function load(liveQuestions) {
  const byId = new Map(liveQuestions.map((q) => [q.id, q]));
  const byDbId = new Map(liveQuestions.map((q) => [q.dbId, q]));
  const context = {
    store: { byId, byDbId },
    getQuestionStore: () => context.store,
    resolveSessionQuestionId: (id) => byDbId.get(id)?.id || id,
    getQbankCourseTopicMeta: (q) => ({ course: String(q.course || ''), topic: String(q.topic || '') }),
  };
  vm.createContext(context);
  vm.runInContext([
    topLevelLine('const QUESTION_CHOICE_LABELS'),
    topLevelLine('const SLIM_SNAPSHOT_REMOVED_STEM'),
    ...[
      'isRecordObject', 'deepClone', 'normalizeQuestionChoiceLabel', 'normalizeQuestionChoiceEntries',
      'normalizeImportDifficulty', 'getNormalizedQuestionCorrectChoiceIds', 'getQuestionFromLookup',
      'getQuestionIdentityCandidates', 'normalizeQuestionForSessionSnapshot', 'isSlimQuestionSnapshot',
      'expandSlimQuestionSnapshot', 'getQuestionSnapshotFromSession', 'mergeSessionQuestionSnapshots',
    ].map(topLevelFunction),
  ].join('\n'), context);
  return context;
}

const liveQuestion = {
  id: 'q-local-1',
  dbId: DB_ID,
  stem: 'Which nerve supplies the deltoid?',
  explanation: 'Axillary nerve (C5-C6).',
  course: 'Anatomy',
  topic: 'Upper limb',
  // The answer key was changed after the test was taken.
  choices: [{ id: 'A', text: 'Radial' }, { id: 'B', text: 'Axillary' }, { id: 'C', text: 'Ulnar' }],
  correct: ['C'],
};

const slim = (dbId) => ({
  id: dbId,
  dbId,
  course: 'Anatomy',
  topic: 'Upper limb',
  choices: [{ id: 'A' }, { id: 'B' }, { id: 'C' }],
  correct: ['B'],
});

test('a slim snapshot takes the live text but keeps its own answer key', () => {
  const ctx = load([liveQuestion]);
  const session = { questionIds: [DB_ID], questionSnapshots: { [DB_ID]: slim(DB_ID) } };
  const question = ctx.getQuestionSnapshotFromSession(session, DB_ID, ctx.store);
  assert.strictEqual(question.stem, liveQuestion.stem);
  assert.strictEqual(question.explanation, liveQuestion.explanation);
  assert.deepStrictEqual(Array.from(question.choices, (c) => c.text), ['Radial', 'Axillary', 'Ulnar']);
  assert.deepStrictEqual(Array.from(question.correct), ['B']);
  assert.ok(!question.removedFromBank);
});

test('a slim snapshot whose question left the bank becomes a labelled placeholder', () => {
  const ctx = load([liveQuestion]);
  const session = { questionIds: [GONE_ID], questionSnapshots: { [GONE_ID]: slim(GONE_ID) } };
  const question = ctx.getQuestionSnapshotFromSession(session, GONE_ID, ctx.store);
  assert.strictEqual(question.removedFromBank, true);
  assert.match(question.stem, /removed from the bank/);
  assert.deepStrictEqual(Array.from(question.correct), ['B']);
  assert.deepStrictEqual(Array.from(question.choices, (c) => c.id), ['A', 'B', 'C']);
});

test('full snapshots are unchanged', () => {
  const ctx = load([liveQuestion]);
  const full = { ...liveQuestion, id: DB_ID, correct: ['B'] };
  const session = { questionIds: [DB_ID], questionSnapshots: { [DB_ID]: full } };
  const question = ctx.getQuestionSnapshotFromSession(session, DB_ID, ctx.store);
  assert.deepStrictEqual(Array.from(question.correct), ['B']);
  assert.strictEqual(question.stem, liveQuestion.stem);
});

test('merging sessions keeps slim snapshots instead of dropping them', () => {
  const ctx = load([]);
  const remote = { questionSnapshots: { [GONE_ID]: slim(GONE_ID) } };
  const merged = ctx.mergeSessionQuestionSnapshots({ questionSnapshots: {} }, remote, false, ctx.store);
  assert.ok(ctx.isSlimQuestionSnapshot(merged[GONE_ID]));
});

test('ensureSessionQuestionSnapshots skips questions whose snapshot is slim', () => {
  const body = topLevelFunction('ensureSessionQuestionSnapshots');
  const slimGuard = body.indexOf('isSlimQuestionSnapshot(snapshots[id])');
  const refill = body.indexOf('getQuestionSnapshotFromSession(session, normalizedQid');
  assert.ok(slimGuard > 0 && slimGuard < refill, 'slim guard must run before the refill from the bank');
});
