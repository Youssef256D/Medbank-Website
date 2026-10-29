'use strict';

// Server-side grading (2026-10-27): a student's bank has no answer key; the
// key comes from submit_test_answer / get_test_answer_key and is written into
// the session's questionSnapshots. A submitted question without a key is
// "being checked", never wrong, and the fetch retries until it gets the key.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const start = mainSource.indexOf(`\nfunction ${name}(`);
  const asyncStart = mainSource.indexOf(`\nasync function ${name}(`);
  const from = start >= 0 ? start : asyncStart;
  const end = mainSource.indexOf('\n}\n', from);
  assert.ok(from >= 0 && end > from, `main.js function moved: ${name}`);
  return mainSource.slice(from, end) + '\n}\n';
};

const BLOCK_ID = '11111111-1111-4111-8111-111111111111';
const Q1 = '22222222-2222-4222-8222-222222222221';
const Q2 = '22222222-2222-4222-8222-222222222222';

const bankQuestion = (id) => ({
  id,
  dbId: id,
  stem: `Stem ${id}`,
  choices: [{ id: 'A', text: 'one' }, { id: 'B', text: 'two' }, { id: 'C', text: 'three' }],
  correct: [],
  explanation: '',
  explanationImage: '',
  answerKeyHidden: true,
});

const KEYS = {
  [Q1]: { correct_labels: ['B'], explanation: 'because B', explanation_image_url: null },
  [Q2]: { correct_labels: ['C'], explanation: 'because C', explanation_image_url: 'https://x/c.png' },
};

// Fake server: holds test_responses and the completed flag, grades like the RPCs.
function fakeServer({ completed = false, capped = [], failSubmit = false } = {}) {
  const server = { rows: {}, completed, calls: [] };
  server.client = {
    rpc: (name, args) => {
      server.calls.push({ name, args });
      if (name === 'submit_test_answer') {
        if (failSubmit) {
          return Promise.resolve({ data: null, error: { message: 'offline' } });
        }
        const existing = server.rows[args.p_question_id];
        if (!existing || !existing.submitted) {
          server.rows[args.p_question_id] = { selected: args.p_selected_labels, submitted: true };
        }
        const stored = server.rows[args.p_question_id];
        const key = KEYS[args.p_question_id];
        return Promise.resolve({
          data: {
            question_id: args.p_question_id,
            selected_labels: stored.selected,
            submitted: true,
            graded: true,
            capped: false,
            correct_labels: key.correct_labels,
            is_correct: stored.selected.join() === key.correct_labels.join(),
            explanation: key.explanation,
            explanation_image_url: key.explanation_image_url,
          },
          error: null,
        });
      }
      if (name === 'get_test_answer_key') {
        const data = args.p_question_ids
          .filter((id) => server.completed || server.rows[id]?.submitted)
          .map((id) => (capped.includes(id)
            ? { question_id: id, correct_labels: null, explanation: null, explanation_image_url: null, capped: true }
            : { question_id: id, ...KEYS[id], capped: false }));
        return Promise.resolve({ data, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
  };
  return server;
}

function harness(session, server, { online = true } = {}) {
  const bank = new Map([[Q1, bankQuestion(Q1)], [Q2, bankQuestion(Q2)]]);
  const store = { byId: bank, byDbId: bank };
  const incorrectQueue = [];
  const upserts = [];
  const timers = [];
  const context = vm.createContext({
    console: { warn: () => {}, log: console.log },
    Date,
    Map,
    Set,
    JSON,
    Promise,
    QUESTION_CHOICE_LABELS: ['A', 'B', 'C', 'D', 'E'],
    SUPABASE_CONFIG: { serverGrading: true },
    state: { route: 'session', sessionId: session.id, reviewSessionId: null },
    window: {
      setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
      addEventListener: () => {},
    },
    getCurrentUser: () => ({ id: 'u1', role: 'student' }),
    getLiveTestBlockContext: () => (online ? { currentUser: { id: 'u1' }, client: server.client, profileId: 'p1' } : null),
    isBrowserOffline: () => !online,
    syncLiveTestBlocks: async () => {
      // Push local submitted answers like the live sync does.
      Object.entries(session.responses).forEach(([qid, response]) => {
        if (response.submitted && response.selected.length && !server.rows[qid]?.submitted) {
          server.rows[qid] = { selected: response.selected.slice(), submitted: true };
        }
      });
      if (session.status === 'completed') server.completed = true;
    },
    getQuestionStore: () => store,
    getSessionById: () => session,
    getSessionsForUser: () => [session],
    getQuestionForSession: (s, qid) => {
      const snapshot = s.questionSnapshots?.[qid];
      return snapshot || store.byId.get(qid) || null;
    },
    getQuestionIdentityCandidates: (question) => [String(question?.id || question || '')].filter(Boolean),
    normalizeQuestionForSessionSnapshot: (question) => (question ? JSON.parse(JSON.stringify(question)) : null),
    getLiveTestBlockQuestionDbId: (s, qid) => qid,
    resolveSessionQuestionId: (qid) => qid,
    isRecordObject: (value) => Boolean(value) && typeof value === 'object' && !Array.isArray(value),
    isUuidValue: (value) => /^[0-9a-f-]{36}$/.test(String(value || '')),
    deepClone: (value) => JSON.parse(JSON.stringify(value)),
    parseSyncTimestampMs: (value) => Date.parse(value) || 0,
    nowISO: () => new Date().toISOString(),
    runRelationalQueryWithTimeout: async (query) => {
      const { data, error } = await query;
      if (error) throw error;
      return data;
    },
    splitIntoBatches: (list, size) => {
      const out = [];
      for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
      return out;
    },
    addQuestionToIncorrectQueue: (userId, qid) => incorrectQueue.push(qid),
    upsertSession: (s) => upserts.push(s.id),
    render: () => {},
    escapeHtml: (value) => String(value ?? ''),
  });
  vm.runInContext(`
    const ANSWER_KEY_RETRY_DELAYS_MS = [3000, 10000, 30000, 120000];
    const ANSWER_KEY_CAPPED_RETRY_MS = 60 * 60 * 1000;
    const ANSWER_KEY_SWEEP_SESSION_LIMIT = 10;
    const answerKeyRuntime = { inFlight: new Map(), retryTimers: new Map(), attempts: new Map(), onlineListener: false };
  `, context);
  [
    'arraysEqual',
    'normalizeQuestionChoiceLabel',
    'normalizeQuestionChoiceEntries',
    'getNormalizedQuestionCorrectChoiceIds',
    'getNormalizedResponseSelectedChoiceIds',
    'isResponseSelectionCorrect',
    'isSubmittedResponseCorrect',
    'getLiveTestBlockSelectedLabels',
    'buildLiveTestBlockAnswerSig',
    'getLiveTestBlockResponse',
    'getSessionQuestionSnapshotMap',
    'isServerGradingActiveForUser',
    'hasQuestionAnswerKey',
    'isSubmittedResponseAwaitingKey',
    'isAnswerKeyCappedRecently',
    'getSessionQuestionsNeedingAnswerKey',
    'writeSessionQuestionSnapshot',
    'applyAnswerKeyToSession',
    'markSessionAnswerKeyCapped',
    'addGradedMistakesToIncorrectQueue',
    'rerenderIfShowingSession',
    'scheduleAnswerKeyRetry',
    'ensureAnswerKeyOnlineListener',
    'requestSessionAnswerKeys',
    'submitSessionAnswerToServer',
    'renderAwaitingAnswerKeyPane',
    'renderInlineExplanationPane',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return { context, incorrectQueue, upserts, timers };
}

function makeSession(responses, extra = {}) {
  return {
    id: 'web-1',
    userId: 'u1',
    status: 'in_progress',
    updatedAt: new Date().toISOString(),
    questionIds: [Q1, Q2],
    liveBlockId: BLOCK_ID,
    liveBlockAnswerSigs: {},
    questionSnapshots: {},
    responses: {
      [Q1]: { selected: [], submitted: false, flagged: false, notes: '' },
      [Q2]: { selected: [], submitted: false, flagged: false, notes: '' },
      ...responses,
    },
    ...extra,
  };
}

test('a submitted question without a key is being checked, not wrong', () => {
  const session = makeSession({ [Q1]: { selected: ['A'], submitted: true, flagged: false, notes: '' } });
  const { context } = harness(session, fakeServer());
  const question = context.getQuestionForSession(session, Q1);
  assert.strictEqual(context.hasQuestionAnswerKey(question), false);
  assert.strictEqual(context.isSubmittedResponseAwaitingKey(question, session.responses[Q1]), true);
  const pane = context.renderInlineExplanationPane(question, false);
  assert.match(pane, /Checking your answer/);
  assert.doesNotMatch(pane, /incorrect/);
});

test('tutor check: submit_test_answer grades and writes the key into the snapshot', async () => {
  const session = makeSession({ [Q1]: { selected: ['A'], submitted: true, flagged: false, notes: '' } });
  const server = fakeServer();
  const { context, incorrectQueue } = harness(session, server);
  const graded = await context.submitSessionAnswerToServer(session.id, Q1);
  assert.strictEqual(graded, true);
  const question = context.getQuestionForSession(session, Q1);
  assert.deepStrictEqual([...question.correct], ['B']);
  assert.strictEqual(question.explanation, 'because B');
  assert.strictEqual(question.answerKeyHidden, undefined);
  assert.strictEqual(context.isSubmittedResponseCorrect(question, session.responses[Q1]), false);
  assert.deepStrictEqual(incorrectQueue, [Q1]);
  assert.strictEqual(session.liveBlockAnswerSigs[Q1], 'A|0|1|');
  assert.match(context.renderInlineExplanationPane(question, false), /The correct answer is: B\. two/);
  // The bank question is untouched.
  assert.deepStrictEqual(context.getQuestionStore().byId.get(Q1).correct, []);
});

test('tutor check: an answer already solved elsewhere wins', async () => {
  const session = makeSession({ [Q1]: { selected: ['A'], submitted: true, flagged: false, notes: '' } });
  const server = fakeServer();
  server.rows[Q1] = { selected: ['B'], submitted: true };
  const { context } = harness(session, server);
  await context.submitSessionAnswerToServer(session.id, Q1);
  assert.deepStrictEqual([...session.responses[Q1].selected], ['B']);
  assert.strictEqual(context.isSubmittedResponseCorrect(context.getQuestionForSession(session, Q1), session.responses[Q1]), true);
});

test('tutor check offline: answer kept, retry scheduled, key fetched later', async () => {
  const session = makeSession({ [Q1]: { selected: ['B'], submitted: true, flagged: false, notes: '' } });
  const server = fakeServer({ failSubmit: true });
  const { context, timers } = harness(session, server);
  const graded = await context.submitSessionAnswerToServer(session.id, Q1);
  assert.strictEqual(graded, false);
  assert.strictEqual(session.responses[Q1].submitted, true);
  assert.strictEqual(timers.length, 1);
  // Back online: the retry pushes the answer and gets the key.
  await context.requestSessionAnswerKeys(session.id);
  const question = context.getQuestionForSession(session, Q1);
  assert.deepStrictEqual([...question.correct], ['B']);
  assert.strictEqual(context.isSubmittedResponseCorrect(question, session.responses[Q1]), true);
});

test('finished test: keys for every question, skipped ones included', async () => {
  const session = makeSession({ [Q1]: { selected: ['B'], submitted: true, flagged: false, notes: '' } }, { status: 'completed' });
  const server = fakeServer();
  const { context, incorrectQueue } = harness(session, server);
  assert.strictEqual(context.getSessionQuestionsNeedingAnswerKey(session).length, 2);
  await context.requestSessionAnswerKeys(session.id);
  assert.strictEqual(context.getSessionQuestionsNeedingAnswerKey(session).length, 0);
  assert.strictEqual(context.getQuestionForSession(session, Q2).explanationImage, 'https://x/c.png');
  // Q1 right, Q2 skipped (wrong) once graded.
  assert.deepStrictEqual(incorrectQueue, [Q2]);
});

test('unfinished test: only solved questions are fetched', async () => {
  const session = makeSession({ [Q2]: { selected: ['C'], submitted: true, flagged: false, notes: '' } });
  const server = fakeServer();
  const { context } = harness(session, server);
  const needed = [...context.getSessionQuestionsNeedingAnswerKey(session)].map((entry) => entry.questionId);
  assert.deepStrictEqual(needed, [Q2]);
  await context.requestSessionAnswerKeys(session.id);
  const call = server.calls.find((entry) => entry.name === 'get_test_answer_key');
  assert.deepStrictEqual([...call.args.p_question_ids], [Q2]);
  assert.deepStrictEqual([...context.getQuestionForSession(session, Q2).correct], ['C']);
});

test('daily cap: the question is marked capped and not asked again for an hour', async () => {
  const session = makeSession({ [Q1]: { selected: ['B'], submitted: true, flagged: false, notes: '' } });
  const server = fakeServer({ capped: [Q1] });
  const { context } = harness(session, server);
  await context.requestSessionAnswerKeys(session.id);
  const question = context.getQuestionForSession(session, Q1);
  assert.ok(question.answerKeyCappedAt);
  assert.strictEqual(context.getSessionQuestionsNeedingAnswerKey(session).length, 0);
  assert.match(context.renderAwaitingAnswerKeyPane(question), /most answers allowed for one day/);
});

test('a bank that still has the key needs no server call', async () => {
  const session = makeSession({ [Q1]: { selected: ['B'], submitted: true, flagged: false, notes: '' } }, {
    questionSnapshots: { [Q1]: { ...bankQuestion(Q1), correct: ['B'], explanation: 'cached', answerKeyHidden: undefined } },
  });
  const server = fakeServer();
  const { context } = harness(session, server);
  assert.strictEqual(await context.requestSessionAnswerKeys(session.id), false);
  assert.strictEqual(server.calls.length, 0);
});

test('admins keep grading from the bank', () => {
  const session = makeSession({});
  const { context } = harness(session, fakeServer());
  assert.strictEqual(context.isServerGradingActiveForUser({ role: 'admin' }), false);
  assert.strictEqual(context.isServerGradingActiveForUser({ role: 'student' }), true);
  assert.strictEqual(context.isServerGradingActiveForUser({ role: 'creator' }), true);
});

test('the bank mapping never invents a key for a hidden one', () => {
  // resolveQuestionCorrectAnswers falls back to "A"; hidden keys must skip it.
  const mapping = mainSource.slice(mainSource.indexOf('const answerKeyHidden = isServerGradingActiveForUser(currentUser)'));
  assert.match(mapping.slice(0, 600), /const correct = answerKeyHidden\s*\? \[\]/);
  assert.match(mainSource, /if \(question\?\.answerKeyHidden === true\) {\n {4}return true;\n {2}}/);
});
