'use strict';

// Admin > Courses > Topics row menu: "Publish all questions" and "Draft all
// questions" change every question in that one topic, ask first, and sync.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const start = mainSource.indexOf(`\nasync function ${name}(`) >= 0
    ? mainSource.indexOf(`\nasync function ${name}(`)
    : mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return mainSource.slice(start, end) + '\n}\n';
};

const setup = ({ questions, confirm = true }) => {
  const calls = { saved: null, toasts: [], confirms: [], flushed: 0 };
  const context = vm.createContext({
    state: { adminBulkActionRunning: false, adminQuestionSaveRunning: false },
    STORAGE_KEYS: { questions: 'questions' },
    getQuestions: () => questions,
    getQbankCourseTopicMeta: (q) => ({ course: q.course, topic: q.topic }),
    save: (key, value) => { calls.saved = value; },
    markAdminQuestionCountsStale: () => {},
    refreshAdminQuestionCountSnapshot: async () => {},
    flushPendingSyncNow: async () => { calls.flushed += 1; },
    getErrorMessage: (e, f) => e?.message || f,
    toast: (m) => calls.toasts.push(m),
    window: { confirm: (m) => { calls.confirms.push(m); return confirm; } },
  });
  vm.runInContext(topLevelFunction('normalizeTopicKey'), context);
  vm.runInContext(topLevelFunction('setCourseTopicQuestionsStatus'), context);
  return { context, calls };
};

const QUESTIONS = [
  { id: 'q1', course: 'Anatomy', topic: 'Upper limb', status: 'draft' },
  { id: 'q2', course: 'Anatomy', topic: 'Upper limb', status: 'published' },
  { id: 'q3', course: 'Anatomy', topic: 'Lower limb', status: 'draft' },
  { id: 'q4', course: 'Physiology', topic: 'Upper limb', status: 'draft' },
];

test('publishes only the drafts in that course and topic', async () => {
  const { context, calls } = setup({ questions: QUESTIONS });
  await context.setCourseTopicQuestionsStatus('Anatomy', 'Upper limb', 'published');
  assert.deepStrictEqual(calls.saved.map((q) => `${q.id}:${q.status}`), [
    'q1:published', 'q2:published', 'q3:draft', 'q4:draft',
  ]);
  assert.match(calls.confirms[0], /Publish 1 question/);
  assert.strictEqual(calls.flushed, 1);
});

test('drafts every published question in the topic', async () => {
  const { context, calls } = setup({ questions: QUESTIONS });
  await context.setCourseTopicQuestionsStatus('Anatomy', 'Upper limb', 'draft');
  assert.deepStrictEqual(calls.saved.map((q) => q.status), ['draft', 'draft', 'draft', 'draft']);
});

test('cancelling the confirmation changes nothing', async () => {
  const { context, calls } = setup({ questions: QUESTIONS, confirm: false });
  await context.setCourseTopicQuestionsStatus('Anatomy', 'Upper limb', 'published');
  assert.strictEqual(calls.saved, null);
  assert.strictEqual(calls.flushed, 0);
});

test('says so when nothing needs changing or the topic is empty', async () => {
  const { context, calls } = setup({ questions: QUESTIONS });
  await context.setCourseTopicQuestionsStatus('Anatomy', 'Lower limb', 'draft');
  await context.setCourseTopicQuestionsStatus('Anatomy', 'Head and neck', 'published');
  assert.strictEqual(calls.saved, null);
  assert.strictEqual(calls.confirms.length, 0);
  assert.match(calls.toasts[0], /already drafts/);
  assert.match(calls.toasts[1], /no questions yet/);
});
