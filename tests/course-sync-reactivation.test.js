'use strict';

// A stale admin tab still listing a deleted course must not switch it back on.
// Only a course the admin added in this browser may reactivate an inactive
// courses row (2026-10-15: CVS/GIL/RES/SOB came back from another admin's iPad).

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
    STORAGE_KEYS: { pendingCourseAdditions: 'additions' },
    load: (key, fallback) => (key in store ? JSON.parse(JSON.stringify(store[key])) : fallback),
    saveLocalOnly: (key, value) => { store[key] = value; },
    sanitizeAcademicYear: (value) => Math.min(5, Math.max(1, Number(value) || 1)),
    sanitizeAcademicSemester: (value) => (Number(value) === 2 ? 2 : 1),
  });
  [
    'courseCompositeKey',
    'getPendingCourseAdditions',
    'queuePendingCourseAddition',
    'clearPendingCourseAdditions',
    'selectCoursesNeedingUpsert',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return context;
}

const desired = (name, code) => ({
  course_name: name, course_code: code, academic_year: 2, academic_semester: 1, is_active: true,
});
const row = (name, code, isActive) => ({
  id: name, course_name: name, course_code: code, academic_year: 2, academic_semester: 1, is_active: isActive,
});
const names = (rows) => rows.map((course) => course.course_name);

test('a deleted course in a stale local curriculum is not reactivated', () => {
  const ctx = harness();
  const result = ctx.selectCoursesNeedingUpsert(
    [desired('CVS', 'CVS 202'), desired('NRS', 'NRS 202')],
    [row('CVS', 'CVS 202', false), row('NRS', 'NRS 202', true)],
    new Set(),
  );
  assert.deepStrictEqual(names(result), []);
});

test('an explicitly added course may reactivate its inactive row', () => {
  const ctx = harness();
  ctx.queuePendingCourseAddition('CVS', 2, 1);
  const result = ctx.selectCoursesNeedingUpsert(
    [desired('CVS', 'CVS 202')],
    [row('CVS', 'CVS 202', false)],
    new Set(ctx.getPendingCourseAdditions()),
  );
  assert.deepStrictEqual(names(result), ['CVS']);
  ctx.clearPendingCourseAdditions(ctx.getPendingCourseAdditions());
  assert.strictEqual(ctx.getPendingCourseAdditions().length, 0);
});

test('new courses are inserted and changed codes are updated', () => {
  const ctx = harness();
  const result = ctx.selectCoursesNeedingUpsert(
    [desired('New', 'NEW 1'), desired('Code', 'COD 2'), desired('Same', 'SAM 1')],
    [row('Code', 'COD 1', true), row('Same', 'SAM 1', true)],
    new Set(),
  );
  assert.deepStrictEqual(names(result), ['New', 'Code']);
});

test('an active duplicate row wins over an inactive one', () => {
  const ctx = harness();
  const result = ctx.selectCoursesNeedingUpsert(
    [desired('Dup', 'DUP 1')],
    [row('Dup', 'DUP 1', false), row('Dup', 'DUP 1', true)],
    new Set(),
  );
  assert.deepStrictEqual(names(result), []);
});

test('the add-course form queues an explicit addition', () => {
  const start = mainSource.indexOf('curriculumAddForm?.addEventListener("submit"');
  const end = mainSource.indexOf("[data-action='course-topic-manager-close']", start);
  assert.ok(start >= 0 && end > start);
  assert.ok(mainSource.slice(start, end).includes('queuePendingCourseAddition('));
});
