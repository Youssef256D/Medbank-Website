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

// Minimal PostgREST stand-in over one in-memory test_responses table.
function fakeClient(rows) {
  const run = (op) => {
    const matches = (row) => op.filters.every(([kind, col, value]) => {
      if (kind === 'eq') {
        if (col === 'selected_choice_labels') return `{${(row.selected_choice_labels || []).join(',')}}` === value;
        return row[col] === value;
      }
      if (kind === 'in') return value.includes(row[col]);
      if (kind === 'or') return !(row.selected_choice_labels || []).length;
      return true;
    });
    if (op.kind === 'update') {
      const hit = rows.filter(matches);
      hit.forEach((row) => {
        Object.assign(row, op.payload);
      });
      return hit.map((row) => ({ question_id: row.question_id }));
    }
    if (op.kind === 'upsert') {
      const inserted = [];
      op.payload.forEach((row) => {
        const existing = rows.find((r) => r.block_id === row.block_id && r.question_id === row.question_id);
        if (!existing) {
          rows.push({ ...row });
          inserted.push({ question_id: row.question_id });
        } else if (!op.options?.ignoreDuplicates) {
          Object.assign(existing, row);
        }
      });
      return inserted;
    }
    if (op.kind === 'select') {
      return rows.filter(matches).map((row) => ({ ...row }));
    }
    return [];
  };
  const builder = (kind, payload, options) => {
    const op = { kind, payload, options, filters: [] };
    const chain = {
      eq: (col, value) => { op.filters.push(['eq', col, value]); return chain; },
      in: (col, value) => { op.filters.push(['in', col, value]); return chain; },
      or: (expr) => { op.filters.push(['or', expr]); return chain; },
      neq: () => chain,
      select: () => chain,
      then: (resolve, reject) => Promise.resolve(run(op)).then(resolve, reject),
    };
    return chain;
  };
  return {
    from: (table) => ({
      update: (payload) => (table === 'test_responses' ? builder('update', payload) : builder('noop')),
      upsert: (payload, options) => builder('upsert', payload, options),
      select: () => builder('select'),
    }),
  };
}

function harness(session, rows) {
  const client = fakeClient(rows);
  const store = { byId: new Map(), byDbId: new Map([[Q1, {}]]) };
  const context = vm.createContext({
    console,
    Date,
    LIVE_TEST_BLOCK_MAX_AGE_MS: 30 * 24 * 60 * 60 * 1000,
    RELATIONAL_UUID_IN_BATCH_SIZE: 100,
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
});
