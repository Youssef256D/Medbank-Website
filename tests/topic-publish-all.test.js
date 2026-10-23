'use strict';

// Admin > Courses > Topics row menu: "Publish all questions" and "Draft all
// questions" change every question of that topic in the database (the local
// copy can be incomplete), ask first, then update the local copy to match.

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

// A chainable stand-in for the Supabase query builder. `rows` are the
// questions in the "database"; the topic lookup returns `topicRows`.
const fakeClient = ({ rows, topicRows }) => {
  const calls = [];
  const from = (table) => {
    const filters = [];
    let update = null;
    const builder = {
      select: () => builder,
      update: (values) => { update = values; return builder; },
      eq: (column, value) => { filters.push([column, value]); return builder; },
      then: (resolve, reject) => {
        calls.push({ table, update, filters });
        if (table === 'course_topics') {
          return Promise.resolve({ data: topicRows, error: null }).then(resolve, reject);
        }
        const matching = rows.filter((row) => filters.every(([column, value]) => row[column] === value));
        if (update) matching.forEach((row) => Object.assign(row, update));
        return Promise.resolve({ data: matching.map((row) => ({ external_id: row.external_id })), error: null }).then(resolve, reject);
      },
    };
    return builder;
  };
  return { client: { from }, calls };
};

const setup = ({ dbRows, localQuestions, serverCounts = null, topicRows = [{ id: 't1' }], confirm = true }) => {
  const { client, calls } = fakeClient({ rows: dbRows, topicRows });
  const log = { savedLocal: null, toasts: [], confirms: [], flushed: 0, refreshed: 0 };
  const context = vm.createContext({
    state: { adminQuestionCountSnapshot: serverCounts },
    relationalSync: { enabled: true },
    STORAGE_KEYS: { questions: 'questions' },
    SUPABASE_QUERY_TIMEOUT_MS: 1000,
    QUESTION_RELATIONAL_TIMEOUT_MS: 1000,
    getRelationalClient: () => client,
    runWithTimeoutResult: (promise) => promise,
    getQuestions: () => localQuestions,
    saveLocalOnly: (key, value) => { log.savedLocal = value; },
    markAdminQuestionCountsStale: () => {},
    refreshAdminQuestionCountSnapshot: async () => { log.refreshed += 1; return true; },
    flushPendingSyncNow: async () => { log.flushed += 1; },
    getErrorMessage: (e, f) => e?.message || f,
    toast: (m) => log.toasts.push(m),
    window: { confirm: (m) => { log.confirms.push(m); return confirm; } },
  });
  vm.runInContext(topLevelFunction('normalizeTopicKey'), context);
  vm.runInContext(topLevelFunction('getCourseTopicServerCounts'), context);
  vm.runInContext(topLevelFunction('fetchCourseTopicId'), context);
  vm.runInContext('let courseTopicServerActionQueue = Promise.resolve();', context);
  vm.runInContext(topLevelFunction('queueCourseTopicServerAction'), context);
  vm.runInContext(topLevelFunction('setCourseTopicQuestionsStatus'), context);
  return { context, calls, log };
};

const snapshot = (byTopic) => ({ byTopic });

test('publishes every draft of the topic in the database, including ones not loaded locally', async () => {
  const dbRows = [
    { external_id: 'q1', topic_id: 't1', status: 'draft' },
    { external_id: 'q2', topic_id: 't1', status: 'draft' }, // not in the local copy
    { external_id: 'q3', topic_id: 't1', status: 'published' },
    { external_id: 'q4', topic_id: 't2', status: 'draft' },
  ];
  const localQuestions = [{ id: 'q1', status: 'draft' }, { id: 'q3', status: 'published' }];
  const { context, calls, log } = setup({
    dbRows,
    localQuestions,
    serverCounts: snapshot([{ courseName: 'NRS', topicName: 'Synapse', published: 1, draft: 2, total: 3 }]),
  });
  const changed = await context.setCourseTopicQuestionsStatus('NRS', 'Synapse', 'published');
  assert.strictEqual(changed, true);
  assert.deepStrictEqual(dbRows.map((r) => `${r.external_id}:${r.status}`), ['q1:published', 'q2:published', 'q3:published', 'q4:draft']);
  assert.match(log.confirms[0], /Publish 2 question/);
  assert.strictEqual(log.flushed, 1, 'pending saves are sent first');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(log.savedLocal)), [{ id: 'q1', status: 'published' }, { id: 'q3', status: 'published' }]);
  assert.match(log.toasts.at(-1), /Published 2 question/);
  const update = calls.find((c) => c.update);
  assert.deepStrictEqual(update.filters, [['topic_id', 't1'], ['status', 'draft']]);
});

test('says so and changes nothing when the server says nothing needs changing', async () => {
  const { context, calls, log } = setup({
    dbRows: [],
    localQuestions: [],
    serverCounts: snapshot([{ courseName: 'NRS', topicName: 'Synapse', published: 5, draft: 0, total: 5 }]),
  });
  assert.strictEqual(await context.setCourseTopicQuestionsStatus('NRS', 'Synapse', 'published'), false);
  assert.strictEqual(log.confirms.length, 0);
  assert.strictEqual(calls.length, 0);
  assert.match(log.toasts[0], /already published/);
});

test('cancelling the confirmation changes nothing', async () => {
  const dbRows = [{ external_id: 'q1', topic_id: 't1', status: 'published' }];
  const { context, log } = setup({ dbRows, localQuestions: [], confirm: false });
  assert.strictEqual(await context.setCourseTopicQuestionsStatus('NRS', 'Synapse', 'draft'), false);
  assert.strictEqual(dbRows[0].status, 'published');
  assert.strictEqual(log.flushed, 0);
});

test('a topic not yet in the database is reported, not guessed', async () => {
  const { context, log } = setup({ dbRows: [], localQuestions: [], topicRows: [] });
  assert.strictEqual(await context.setCourseTopicQuestionsStatus('NRS', 'New topic', 'published'), false);
  assert.match(log.toasts.at(-1), /not saved to the database yet/);
});

test('two topics clicked quickly both change', async () => {
  const dbRows = [
    { external_id: 'a', topic_id: 't1', status: 'draft' },
    { external_id: 'b', topic_id: 't1', status: 'draft' },
  ];
  const { context } = setup({ dbRows, localQuestions: [] });
  await Promise.all([
    context.setCourseTopicQuestionsStatus('NRS', 'One', 'published'),
    context.setCourseTopicQuestionsStatus('NRS', 'Two', 'published'),
  ]);
  assert.deepStrictEqual(dbRows.map((r) => r.status), ['published', 'published']);
});
