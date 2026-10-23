'use strict';

// Admin > Courses > Topics: renaming a topic renames its row in the database
// first, so questions missing from the (partial) local copy stay on it instead
// of being left on the old, switched-off topic.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const asyncStart = mainSource.indexOf(`\nasync function ${name}(`);
  const start = asyncStart >= 0 ? asyncStart : mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return mainSource.slice(start, end) + '\n}\n';
};

// `topics` and `questions` are the "database" rows.
const setup = ({ topics, questions, failUpdate = false }) => {
  const from = (table) => {
    const filters = [];
    let update = null;
    const builder = {
      select: () => builder,
      update: (values) => { update = values; return builder; },
      eq: (column, value) => { filters.push([column, value]); return builder; },
      then: (resolve, reject) => {
        if (update && failUpdate) {
          return Promise.resolve({ data: null, error: new Error('denied') }).then(resolve, reject);
        }
        const rows = table === 'course_topics' ? topics : questions;
        const matching = rows.filter((row) => filters.every(([column, value]) => (
          column === 'courses.course_name' ? row.course === value : row[column] === value
        )));
        if (update) matching.forEach((row) => Object.assign(row, update));
        return Promise.resolve({ data: matching.map((row) => ({ id: row.id })), error: null }).then(resolve, reject);
      },
    };
    return builder;
  };
  const log = { toasts: [], flushed: 0 };
  const context = vm.createContext({
    relationalSync: { enabled: true },
    SUPABASE_QUERY_TIMEOUT_MS: 1000,
    QUESTION_RELATIONAL_TIMEOUT_MS: 1000,
    getRelationalClient: () => ({ from }),
    runWithTimeoutResult: (promise) => promise,
    markAdminQuestionCountsStale: () => {},
    flushPendingSyncNow: async () => { log.flushed += 1; },
    getErrorMessage: (e, f) => e?.message || f,
    toast: (m) => log.toasts.push(m),
  });
  vm.runInContext(topLevelFunction('fetchCourseTopicId'), context);
  vm.runInContext('let courseTopicServerActionQueue = Promise.resolve();', context);
  vm.runInContext(topLevelFunction('queueCourseTopicServerAction'), context);
  vm.runInContext(topLevelFunction('renameCourseTopicOnServer'), context);
  return { context, log };
};

test('renames the topic row in place so every question stays on it', async () => {
  const topics = [{ id: 't1', course: 'IHI', topic_name: 'Mid 2025', is_active: true }];
  const questions = [{ id: 'q1', topic_id: 't1' }, { id: 'q2', topic_id: 't1' }];
  const { context, log } = setup({ topics, questions });
  const ok = await context.renameCourseTopicOnServer('IHI', 'Mid 2025', '🔥 Mid 2025');
  assert.strictEqual(ok, true);
  assert.strictEqual(log.flushed, 1);
  assert.strictEqual(topics[0].topic_name, '🔥 Mid 2025');
  assert.deepStrictEqual(questions.map((q) => q.topic_id), ['t1', 't1']);
});

test('moves the questions when a row with the new name already exists', async () => {
  const topics = [
    { id: 't1', course: 'IHI', topic_name: 'Mid 2025', is_active: true },
    { id: 't2', course: 'IHI', topic_name: 'Old Mid', is_active: false },
  ];
  const questions = [{ id: 'q1', topic_id: 't1' }, { id: 'q2', topic_id: 't3' }];
  const { context } = setup({ topics, questions });
  const ok = await context.renameCourseTopicOnServer('IHI', 'Mid 2025', 'Old Mid');
  assert.strictEqual(ok, true);
  assert.deepStrictEqual(questions.map((q) => q.topic_id), ['t2', 't3']);
  assert.strictEqual(topics[1].is_active, true);
  assert.strictEqual(topics[0].topic_name, 'Mid 2025');
});

test('a failed database rename stops the rename', async () => {
  const topics = [{ id: 't1', course: 'IHI', topic_name: 'Mid 2025', is_active: true }];
  const { context, log } = setup({ topics, questions: [], failUpdate: true });
  const ok = await context.renameCourseTopicOnServer('IHI', 'Mid 2025', 'New');
  assert.strictEqual(ok, false);
  assert.match(log.toasts[0], /Could not rename "Mid 2025": denied/);
});
