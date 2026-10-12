'use strict';

// Deleting a topic queues it with deleteQuestions:true so the course sync also
// permanently deletes the topic's questions on the server. Renames reuse the
// same queue for the old name and must NOT carry the flag, or the sync would
// delete the renamed topic's questions.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const start = mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return mainSource.slice(start, end) + '\n}\n';
};

function harness() {
  const store = {};
  const context = vm.createContext({
    STORAGE_KEYS: { pendingCourseTopicDeletions: 'pending' },
    load: (key, fallback) => (key in store ? JSON.parse(JSON.stringify(store[key])) : fallback),
    saveLocalOnly: (key, value) => { store[key] = value; },
    normalizeTopicKey: (value) => String(value || '').trim().toLowerCase(),
  });
  [
    'normalizePendingCourseTopicDeletionEntry',
    'getPendingCourseTopicDeletions',
    'savePendingCourseTopicDeletions',
    'queuePendingCourseTopicDeletion',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return context;
}

test('a delete carries deleteQuestions, a rename does not', () => {
  const ctx = harness();
  ctx.queuePendingCourseTopicDeletion('Gyn', 'Old name');
  ctx.queuePendingCourseTopicDeletion('Gyn', 'Removed', { deleteQuestions: true });
  const entries = ctx.getPendingCourseTopicDeletions();
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(entries.map((entry) => [entry.topicName, entry.deleteQuestions]))),
    [['Old name', false], ['Removed', true]],
  );
});

test('a later rename entry never clears a queued delete', () => {
  const ctx = harness();
  ctx.queuePendingCourseTopicDeletion('Gyn', 'Topic', { deleteQuestions: true });
  ctx.queuePendingCourseTopicDeletion('Gyn', 'topic');
  const entries = ctx.getPendingCourseTopicDeletions();
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].deleteQuestions, true);
});

test('entries queued before this change load as non-deleting', () => {
  const ctx = harness();
  ctx.saveLocalOnly('pending', [{ courseName: 'Gyn', topicName: 'Legacy' }]);
  assert.strictEqual(ctx.getPendingCourseTopicDeletions()[0].deleteQuestions, false);
});
