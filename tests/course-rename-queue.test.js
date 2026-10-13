'use strict';

// Renaming a course queues an in-place rename of the existing courses row.
// It must not queue the old name for deletion: questions hang off courses.id,
// so retiring the old row hides every question in the course (2026-10-13).

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
    STORAGE_KEYS: { pendingCourseRenames: 'renames' },
    load: (key, fallback) => (key in store ? JSON.parse(JSON.stringify(store[key])) : fallback),
    saveLocalOnly: (key, value) => { store[key] = value; },
    sanitizeAcademicYear: (value) => Math.min(5, Math.max(1, Number(value) || 1)),
    sanitizeAcademicSemester: (value) => (Number(value) === 2 ? 2 : 1),
  });
  [
    'getPendingCourseRenames',
    'queuePendingCourseRename',
    'clearPendingCourseRenames',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return context;
}

test('renames queue in order and clear by count', () => {
  const ctx = harness();
  ctx.queuePendingCourseRename('A (A 1)', 'B (B 1)', 1, 1);
  ctx.queuePendingCourseRename('B (B 1)', 'C (C 1)', 1, 1);
  ctx.queuePendingCourseRename('Same', 'Same', 1, 1);
  const queued = ctx.getPendingCourseRenames();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(queued)), [
    { fromName: 'A (A 1)', toName: 'B (B 1)', academicYear: 1, academicSemester: 1 },
    { fromName: 'B (B 1)', toName: 'C (C 1)', academicYear: 1, academicSemester: 1 },
  ]);
  ctx.clearPendingCourseRenames(1);
  assert.strictEqual(ctx.getPendingCourseRenames().length, 1);
  assert.strictEqual(ctx.getPendingCourseRenames()[0].toName, 'C (C 1)');
});

test('the rename button no longer queues the old course for deletion', () => {
  const start = mainSource.indexOf("[data-action='curriculum-rename']");
  const end = mainSource.indexOf("[data-action='curriculum-delete']", start);
  const handler = mainSource.slice(start, end);
  assert.ok(handler.includes('queuePendingCourseRename('));
  assert.ok(!handler.includes('queuePendingCourseDeletion('));
});
