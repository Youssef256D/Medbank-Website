'use strict';

// 1. Topic order: Move to top / up / down in the admin topic menu.
// 2. A change saved while an earlier one is still being sent must not be
//    lost. Publishing two topics quickly used to drop the second: the first
//    send finished and deleted the queue entry the second had replaced.

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

// Arrays built inside the vm context have another Array prototype.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('moveCourseTopic moves to top, up and down, and refuses impossible moves', () => {
  const context = vm.createContext({});
  vm.runInContext(topLevelFunction('moveCourseTopic'), context);
  const topics = ['A', 'B', 'C', 'D'];
  assert.deepStrictEqual(plain(context.moveCourseTopic(topics, 2, 'top')), ['C', 'A', 'B', 'D']);
  assert.deepStrictEqual(plain(context.moveCourseTopic(topics, 2, 'up')), ['A', 'C', 'B', 'D']);
  assert.deepStrictEqual(plain(context.moveCourseTopic(topics, 1, 'down')), ['A', 'C', 'B', 'D']);
  assert.strictEqual(context.moveCourseTopic(topics, 0, 'up'), topics);
  assert.strictEqual(context.moveCourseTopic(topics, 0, 'top'), topics);
  assert.strictEqual(context.moveCourseTopic(topics, 3, 'down'), topics);
  assert.deepStrictEqual(topics, ['A', 'B', 'C', 'D'], 'input list is not changed');
});

test('a save made while a send is in flight is kept and sent next', async () => {
  const sent = [];
  let releaseFirstSend;
  const timers = [];
  const relationalSync = {
    enabled: true,
    flushing: false,
    flushTimer: null,
    pendingWrites: new Map(),
    pendingWriteMeta: new Map(),
    inFlightPayloadSignatures: new Map(),
    inFlightWriteMeta: new Map(),
    lastSyncedPayloadSignatures: new Map(),
    lastSyncedWriteMeta: new Map(),
    lastRejectedPayloadSignatures: new Map(),
    lastRejectedWriteMeta: new Map(),
  };
  const context = vm.createContext({
    relationalSync,
    STORAGE_KEYS: { questions: 'questions', curriculum: 'curriculum', courseTopics: 'courseTopics', users: 'users', sessions: 'sessions' },
    RELATIONAL_COMBINED_COURSE_SYNC_MARKER: '__combined',
    RELATIONAL_RETRY_FLUSH_MS: 800,
    AUTO_STUDENT_REFRESH_SYNC_KEYS: new Set(),
    navigator: { onLine: true },
    window: { setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; } },
    clearRelationalFlushTimer: () => { relationalSync.flushTimer = null; },
    scheduleSyncStatusUiRefresh: () => {},
    getRelationalSyncPriority: () => 0,
    getSyncPayloadSignature: (payload) => JSON.stringify(payload),
    getRelationalRetryDelayMs: () => 800,
    getCurrentUser: () => null,
    getUsers: () => [],
    syncRelationalKey: async (key, payload) => {
      sent.push(payload.label);
      if (payload.label === 'first') {
        await new Promise((resolve) => { releaseFirstSend = resolve; });
      }
    },
  });
  vm.runInContext(topLevelFunction('flushRelationalWrites'), context);

  relationalSync.pendingWrites.set('questions', { label: 'first' });
  const firstFlush = context.flushRelationalWrites();
  // The second publish saves while the first is still being sent.
  relationalSync.pendingWrites.set('questions', { label: 'second' });
  releaseFirstSend();
  await firstFlush;

  assert.deepStrictEqual(sent, ['first']);
  assert.strictEqual(relationalSync.pendingWrites.get('questions')?.label, 'second', 'the newer save is still queued');
  assert.ok(timers.length > 0, 'a follow-up send is scheduled');

  await context.flushRelationalWrites();
  assert.deepStrictEqual(sent, ['first', 'second']);
  assert.strictEqual(relationalSync.pendingWrites.size, 0);
});
