'use strict';

// Shared tests (test_blocks / test_responses): a question the student solved
// on the website came back unsolved. The push for the solved answer was
// skipped when the row there already held the unsubmitted pick (the device's
// record of what it sent was stale), yet the record was updated as if it had
// been sent, so the next pull took the old unsubmitted copy.

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
const Q1 = '22222222-2222-4222-8222-222222222222';

// Stand-in for the two RPCs over one in-memory test_responses table and one
// block. It follows the rules in
// supabase/migrations/20261027120000_shared_test_write_rpcs.sql (the SQL
// itself is checked by supabase/tests/shared_test_write_rpcs.sql).
function fakeClient(rows, block = { id: BLOCK_ID, status: 'in_progress' }, calls = []) {
  const labels = (value) => [...new Set((Array.isArray(value) ? value : []).map((l) => String(l).trim().toUpperCase()).filter((l) => /^[A-E]$/.test(l)))];
  const saveResponses = ({ p_rows: input }) => input.map((entry) => {
    let row = rows.find((r) => r.block_id === BLOCK_ID && r.question_id === entry.question_id);
    if (!row) {
      row = { block_id: BLOCK_ID, question_id: entry.question_id, selected_choice_labels: [], submitted: false, flagged: false, notes: null };
      rows.push(row);
    }
    const selected = labels(entry.selected);
    const solved = row.submitted && row.selected_choice_labels.length > 0;
    let write = block.status !== 'completed' && selected.length > 0 && !solved;
    if (write && 'expected' in entry && !entry.submitted && row.selected_choice_labels.length) {
      write = labels(entry.expected).join() === row.selected_choice_labels.join();
    }
    if (write) {
      row.selected_choice_labels = selected;
      row.submitted = entry.submitted === true;
    }
    if ('flagged' in entry) row.flagged = entry.flagged === true;
    if ('notes' in entry) row.notes = entry.notes;
    return { ...row };
  });
  const saveProgress = (params) => {
    if (block.status !== 'completed' && params.p_status) block.status = params.p_status;
    return { ...block, updated_at: 'remote-1' };
  };
  return {
    rpc: (name, params) => {
      calls.push({ name, params });
      if (name === 'save_test_responses') return Promise.resolve(saveResponses(params));
      if (name === 'save_test_block_progress') return Promise.resolve(saveProgress(params));
      return Promise.reject(new Error(`unexpected rpc ${name}`));
    },
  };
}

function harness(session, rows, block, calls) {
  const client = fakeClient(rows, block, calls);
  const store = { byId: new Map(), byDbId: new Map([[Q1, {}]]) };
  const context = vm.createContext({
    console,
    Date,
    LIVE_TEST_BLOCK_MAX_AGE_MS: 30 * 24 * 60 * 60 * 1000,
    liveTestBlockRuntime: { timer: null, inFlight: false, queued: false },
    getLiveTestBlockContext: () => ({ currentUser: { id: 'u1' }, client, profileId: 'p1' }),
    getQuestionStore: () => store,
    getSessionsForUser: () => [session],
    getSessionById: () => session,
    parseSyncTimestampMs: (value) => Date.parse(value) || 0,
    isRecordObject: (value) => Boolean(value) && typeof value === 'object' && !Array.isArray(value),
    isUuidValue: (value) => /^[0-9a-f-]{36}$/.test(String(value || '')),
    resolveSessionQuestionId: (id) => id,
    normalizeQuestionChoiceLabel: (label) => (/^[A-E]$/.test(String(label || '').toUpperCase()) ? String(label).toUpperCase() : ''),
    getLiveTestBlockQuestionDbId: (s, id) => id,
    getLiveTestBlockVisibleDbIds: (ids) => ids.slice(),
    getLiveTestBlockProgressPatch: () => ({ current_index: 0 }),
    runRelationalQueryWithTimeout: (query) => Promise.resolve(query),
    splitIntoBatches: (list, size) => {
      const out = [];
      for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
      return out;
    },
    buildEmptyTextHighlightStore: () => ({ lines: {}, choices: {} }),
    scheduleSessionStorePersist: () => {},
    scheduleLiveTestBlockSync: () => {},
    nowISO: () => new Date().toISOString(),
  });
  [
    'getLiveTestBlockSelectedLabels',
    'buildLiveTestBlockAnswerSig',
    'buildLiveTestBlockSignature',
    'getLiveTestBlockResponse',
    'buildEmptyLiveTestBlockResponse',
    'applyLiveTestBlockResponses',
    'syncLiveTestBlocks',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return context;
}

function solvedSession(answerSigs) {
  return {
    id: 'web-1',
    status: 'in_progress',
    updatedAt: new Date().toISOString(),
    questionIds: [Q1],
    currentIndex: 0,
    liveBlockId: BLOCK_ID,
    liveBlockSig: 'old',
    liveBlockAnswerSigs: answerSigs,
    responses: { [Q1]: { selected: ['A'], submitted: true, flagged: false, notes: '' } },
  };
}

const pullRows = (rows) => rows.map((row) => ({ ...row }));

test('a solved answer reaches the row even when the device record is stale', async () => {
  // The row holds the unsubmitted pick; the device lost its record of it.
  const rows = [{ block_id: BLOCK_ID, question_id: Q1, selected_choice_labels: ['A'], submitted: false, flagged: false, notes: '' }];
  const session = solvedSession({});
  const context = harness(session, rows);
  await context.syncLiveTestBlocks();
  assert.strictEqual(rows[0].submitted, true);

  // And the next pull keeps it solved.
  context.applyLiveTestBlockResponses(session, [Q1], pullRows(rows), { byId: new Map() });
  assert.strictEqual(session.responses[Q1].submitted, true);
});

test('a pull never unsolves a solved question the record says was sent', () => {
  const rows = [{ block_id: BLOCK_ID, question_id: Q1, selected_choice_labels: ['A'], submitted: false, flagged: false, notes: '' }];
  const session = solvedSession({ [Q1]: 'A|0|1|' });
  const context = harness(session, rows);
  context.applyLiveTestBlockResponses(session, [Q1], pullRows(rows), { byId: new Map() });
  assert.strictEqual(session.responses[Q1].submitted, true);
  assert.deepStrictEqual([...session.responses[Q1].selected], ['A']);
  // The record is dropped so the next push sends the solved answer again.
  assert.strictEqual(session.liveBlockAnswerSigs[Q1], undefined);
});

test('an answer submitted in the app still comes in', () => {
  const rows = [{ block_id: BLOCK_ID, question_id: Q1, selected_choice_labels: ['C'], submitted: true, flagged: false, notes: '' }];
  const session = solvedSession({ [Q1]: 'A|0|1|' });
  const context = harness(session, rows);
  context.applyLiveTestBlockResponses(session, [Q1], pullRows(rows), { byId: new Map() });
  assert.deepStrictEqual([...session.responses[Q1].selected], ['C']);
  assert.strictEqual(session.responses[Q1].submitted, true);
});

test('a skipped push does not replace an answer the app already submitted', async () => {
  const rows = [{ block_id: BLOCK_ID, question_id: Q1, selected_choice_labels: ['C'], submitted: true, flagged: false, notes: '' }];
  const session = solvedSession({});
  const context = harness(session, rows);
  await context.syncLiveTestBlocks();
  assert.deepStrictEqual(rows[0].selected_choice_labels, ['C']);
  // The block is pulled on the next hydrate, which brings the app's answer in.
  assert.strictEqual(session.liveBlockRemoteAt, '');
  context.applyLiveTestBlockResponses(session, [Q1], pullRows(rows), { byId: new Map() });
  assert.deepStrictEqual([...session.responses[Q1].selected], ['C']);
});

test('an unsubmitted pick changed in the app is not overwritten', async () => {
  const rows = [{ block_id: BLOCK_ID, question_id: Q1, selected_choice_labels: ['B'], submitted: false, flagged: false, notes: '' }];
  const session = solvedSession({ [Q1]: 'A|0|0|' });
  session.responses[Q1] = { selected: ['C'], submitted: false, flagged: false, notes: '' };
  const calls = [];
  const context = harness(session, rows, undefined, calls);
  await context.syncLiveTestBlocks();
  assert.deepStrictEqual([...calls[0].params.p_rows[0].expected], ['A']);
  assert.deepStrictEqual(rows[0].selected_choice_labels, ['B']);
  context.applyLiveTestBlockResponses(session, [Q1], pullRows(rows), { byId: new Map() });
  assert.deepStrictEqual([...session.responses[Q1].selected], ['B']);
});

test('a flag on an unanswered question sends no selection', async () => {
  const rows = [{ block_id: BLOCK_ID, question_id: Q1, selected_choice_labels: ['D'], submitted: false, flagged: false, notes: '' }];
  const session = solvedSession({ [Q1]: '|0|0|' });
  session.responses[Q1] = { selected: [], submitted: false, flagged: true, notes: '' };
  const calls = [];
  const context = harness(session, rows, undefined, calls);
  await context.syncLiveTestBlocks();
  assert.strictEqual('selected' in calls[0].params.p_rows[0], false);
  assert.deepStrictEqual(rows[0].selected_choice_labels, ['D']);
  assert.strictEqual(rows[0].flagged, true);
});

test('finishing on the website completes the block through the progress RPC', async () => {
  const rows = [];
  const session = solvedSession({ [Q1]: 'A|0|1|' });
  session.status = 'completed';
  session.completedAt = '2026-10-27T10:00:00.000Z';
  const block = { id: BLOCK_ID, status: 'in_progress' };
  const calls = [];
  const context = harness(session, rows, block, calls);
  await context.syncLiveTestBlocks();
  const progress = calls.find((call) => call.name === 'save_test_block_progress');
  assert.strictEqual(progress.params.p_status, 'completed');
  assert.strictEqual(progress.params.p_completed_at, '2026-10-27T10:00:00.000Z');
  assert.strictEqual(block.status, 'completed');
  assert.strictEqual(session.liveBlockClosed, true);
});
