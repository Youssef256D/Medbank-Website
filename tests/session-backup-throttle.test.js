'use strict';

// The app_state mcq_sessions backup re-sends every session (up to 1 MB+). It
// used to go up after every answer and every session render, which was 93% of
// all DB writes on 2026-10-25. It is now sent at most once per
// SESSION_STATE_BACKUP_SYNC_MS, while flushPendingSyncNow (hide, close, save
// and exit, logout) still forces it out. Completed-test history still goes to
// the relational tables straight away.

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

function harness(options = {}) {
  const clock = { now: 1_000_000 };
  const backupWrites = [];
  const relationalWrites = [];
  const timers = new Map();
  let nextTimerId = 1;
  const forcedFlushes = [];
  const context = vm.createContext({
    Date: { now: () => clock.now },
    console,
    STORAGE_KEYS: { sessions: 'mcq_sessions' },
    SESSION_SYNC_FLUSH_MS: 600,
    SESSION_STATE_BACKUP_SYNC_MS: 60000,
    sessionSyncRuntime: {
      timer: null, dirty: false, clockDirty: false, lastQueuedAt: 0,
      backupDirty: false, backupTimer: null, lastBackupQueuedAt: 0, flushing: false,
    },
    getSessions: () => options.sessions || [{ id: 's1' }],
    getCompletedSessionsForRelationalHistorySync: () => options.completed || [],
    getSessionsForSupabaseStateBackup: (sessions) => sessions,
    scheduleRelationalWrite: (key, value) => { relationalWrites.push(clock.now); return true; },
    scheduleSupabaseWrite: (key, value) => {
      if (options.backupOff) return false;
      backupWrites.push(clock.now);
      return true;
    },
    flushSessionStateSync: async (opts) => {
      forcedFlushes.push(clock.now);
      context.queueSessionStateForCloud(opts);
    },
    window: {
      setTimeout: (fn, ms) => { const id = nextTimerId++; timers.set(id, { fn, at: clock.now + ms }); return id; },
      clearTimeout: (id) => { timers.delete(id); },
    },
  });
  ['clearSessionBackupTimer', 'scheduleSessionBackupTimer', 'queueSessionStateBackup', 'queueSessionStateForCloud']
    .forEach((name) => vm.runInContext(topLevelFunction(name), context));
  const advance = (ms) => {
    clock.now += ms;
    for (const [id, timer] of [...timers]) {
      if (timer.at <= clock.now) {
        timers.delete(id);
        timer.fn();
      }
    }
  };
  // One answer: the session is marked dirty and queued, as the 600 ms
  // session sync timer would do.
  const answer = () => {
    context.sessionSyncRuntime.dirty = true;
    return context.queueSessionStateForCloud();
  };
  return { context, clock, backupWrites, relationalWrites, timers, forcedFlushes, advance, answer };
}

test('the first change sends the backup straight away', () => {
  const h = harness();
  h.answer();
  assert.equal(h.backupWrites.length, 1);
  assert.equal(h.context.sessionSyncRuntime.backupDirty, false);
});

test('answers inside the window are held back, then sent once', () => {
  const h = harness();
  h.answer();
  for (let i = 0; i < 20; i += 1) {
    h.advance(2000);
    h.answer();
  }
  assert.equal(h.backupWrites.length, 1);
  assert.equal(h.context.sessionSyncRuntime.backupDirty, true);
  assert.equal(h.context.sessionSyncRuntime.dirty, false);
  assert.equal(h.timers.size, 1, 'one backup timer, not one per answer');
  h.advance(20000);
  assert.equal(h.backupWrites.length, 2);
  assert.equal(h.context.sessionSyncRuntime.backupDirty, false);
});

test('ten minutes of answering every 7 s sends about ten backups instead of ~85', () => {
  const h = harness();
  for (let t = 0; t < 600000; t += 7000) {
    h.answer();
    h.advance(7000);
  }
  assert.ok(h.backupWrites.length <= 11, `expected <= 11 backups, got ${h.backupWrites.length}`);
  assert.ok(h.backupWrites.length >= 9, `expected >= 9 backups, got ${h.backupWrites.length}`);
});

test('a forced flush (hide, close, save and exit, logout) sends a held backup at once', () => {
  const h = harness();
  h.answer();
  h.advance(5000);
  h.answer();
  assert.equal(h.backupWrites.length, 1);
  h.context.queueSessionStateForCloud({ forceBackup: true });
  assert.equal(h.backupWrites.length, 2);
  assert.equal(h.context.sessionSyncRuntime.backupDirty, false);
  assert.equal(h.timers.size, 0, 'the pending backup timer is cleared');
});

test('a forced flush with nothing pending sends nothing', () => {
  const h = harness();
  h.answer();
  h.advance(5000);
  assert.equal(h.context.queueSessionStateForCloud({ forceBackup: true }), false);
  assert.equal(h.backupWrites.length, 1);
});

test('completed-test history still goes to the relational tables on every change', () => {
  const h = harness({ completed: [{ id: 's1' }] });
  h.answer();
  h.advance(2000);
  h.answer();
  assert.equal(h.relationalWrites.length, 2);
  assert.equal(h.backupWrites.length, 1);
});

test('when backup sync is off the flag is not left set (it would block cloud reads)', () => {
  const h = harness({ backupOff: true });
  h.answer();
  assert.equal(h.context.sessionSyncRuntime.backupDirty, false);
  h.advance(5000);
  h.answer();
  h.advance(60000);
  assert.equal(h.context.sessionSyncRuntime.backupDirty, false);
});

test('a backup timer that fires mid-flush retries instead of dropping the backup', () => {
  const h = harness();
  h.answer();
  h.advance(5000);
  h.answer();
  h.context.sessionSyncRuntime.flushing = true;
  h.advance(55000);
  assert.equal(h.backupWrites.length, 1);
  assert.equal(h.timers.size, 1);
  h.context.sessionSyncRuntime.flushing = false;
  h.advance(600);
  assert.equal(h.backupWrites.length, 2);
});

test('flushPendingSyncNow forces the backup', () => {
  const start = mainSource.indexOf('\nasync function flushPendingSyncNow(');
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(mainSource.slice(start, end).includes('queueSessionStateForCloud({ forceBackup: true })'));
});

test('a held backup counts as pending session sync so a cloud pull cannot overwrite it', () => {
  const body = topLevelFunction('hasPendingSessionSyncForId');
  assert.ok(body.includes('sessionSyncRuntime.backupDirty'));
});
