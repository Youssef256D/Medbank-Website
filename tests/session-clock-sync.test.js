'use strict';

// The exam clock ticks every second; each tick used to queue a cloud write of
// the whole mcq_sessions blob. Clock-only ticks are now held back to one write
// per SESSION_CLOCK_CLOUD_SYNC_MS, while any other session change (and any
// immediate save) still syncs straight away.

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
  const clock = { now: 1_000_000 };
  const flushes = [];
  const timers = [];
  const context = vm.createContext({
    Date: { now: () => clock.now },
    console,
    SESSION_SYNC_FLUSH_MS: 600,
    SESSION_CLOCK_CLOUD_SYNC_MS: 15000,
    sessionSyncRuntime: { timer: null, dirty: false, clockDirty: false, lastQueuedAt: 0, flushing: false },
    scheduleSyncStatusUiRefresh: () => {},
    flushSessionStateSync: async () => { flushes.push(clock.now); },
    window: { setTimeout: (fn) => { timers.push(fn); return timers.length; } },
  });
  vm.runInContext(topLevelFunction('scheduleSessionStateSync'), context);
  // Stand-in for queueSessionStateForCloud succeeding when the timer fires.
  const runTimers = () => {
    while (timers.length) {
      timers.shift()();
      context.sessionSyncRuntime.timer = null;
      context.sessionSyncRuntime.dirty = false;
      context.sessionSyncRuntime.clockDirty = false;
      context.sessionSyncRuntime.lastQueuedAt = clock.now;
    }
  };
  return { context, clock, flushes, timers, runTimers };
}

test('clock ticks inside the window are held back, not queued', () => {
  const h = harness();
  h.context.sessionSyncRuntime.lastQueuedAt = h.clock.now;
  for (let i = 0; i < 14; i += 1) {
    h.clock.now += 1000;
    h.context.scheduleSessionStateSync({ clockTick: true });
  }
  assert.equal(h.timers.length, 0);
  assert.equal(h.context.sessionSyncRuntime.dirty, false);
  assert.equal(h.context.sessionSyncRuntime.clockDirty, true);
});

test('a clock tick after the window queues one write', () => {
  const h = harness();
  h.context.sessionSyncRuntime.lastQueuedAt = h.clock.now;
  h.clock.now += 15000;
  h.context.scheduleSessionStateSync({ clockTick: true });
  assert.equal(h.timers.length, 1);
  assert.equal(h.context.sessionSyncRuntime.dirty, true);
});

test('a minute of ticks produces about four cloud writes instead of sixty', () => {
  const h = harness();
  for (let i = 0; i < 60; i += 1) {
    h.clock.now += 1000;
    h.context.scheduleSessionStateSync({ clockTick: true });
    h.runTimers();
  }
  assert.ok(h.flushes.length <= 5, `expected <= 5 writes, got ${h.flushes.length}`);
  assert.ok(h.flushes.length >= 4, `expected >= 4 writes, got ${h.flushes.length}`);
});

test('answers and other non-clock changes still sync immediately', () => {
  const h = harness();
  h.context.sessionSyncRuntime.lastQueuedAt = h.clock.now;
  h.clock.now += 1000;
  h.context.scheduleSessionStateSync();
  assert.equal(h.timers.length, 1);
  assert.equal(h.context.sessionSyncRuntime.dirty, true);
});

test('an immediate save (hide/close/submit) bypasses the window', async () => {
  const h = harness();
  h.context.sessionSyncRuntime.lastQueuedAt = h.clock.now;
  h.clock.now += 1000;
  h.context.scheduleSessionStateSync({ clockTick: true, immediate: true });
  assert.equal(h.flushes.length, 1);
});

test('a pending non-clock change is never delayed by a clock tick', () => {
  const h = harness();
  h.context.sessionSyncRuntime.lastQueuedAt = h.clock.now;
  h.context.sessionSyncRuntime.dirty = true;
  h.clock.now += 1000;
  h.context.scheduleSessionStateSync({ clockTick: true });
  assert.equal(h.timers.length, 1);
});

test('the session timer tick is the only caller marked as a clock tick', () => {
  const marked = mainSource.match(/clockTick: true/g) || [];
  assert.equal(marked.length, 1);
  const tickStart = mainSource.indexOf('timerHandle = window.setInterval(() => {');
  const tickEnd = mainSource.indexOf('}, 1000);', tickStart);
  assert.ok(mainSource.slice(tickStart, tickEnd).includes('persistOptions: { clockTick: true }'));
});
