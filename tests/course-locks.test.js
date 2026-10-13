const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');

function sliceFunction(name) {
  const start = mainSource.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in main.js`);
  const end = mainSource.indexOf('\n}\n', start);
  return mainSource.slice(start, end + 3);
}

const context = vm.createContext({});
vm.runInContext(
  `${sliceFunction('resolveEffectiveCourseLocks')}
  this.api = { resolveEffectiveCourseLocks };`,
  context,
);
const { resolveEffectiveCourseLocks } = context.api;

const gyn = { course_id: 'c1', courses: { course_name: 'Gyn 504' } };
const peds = { course_id: 'c2', courses: { course_name: 'Peds 505' } };

const names = (locks) => Array.from(locks, (lock) => lock.courseName).sort();

test('universal lock applies when the student has no override', () => {
  assert.deepEqual(names(resolveEffectiveCourseLocks([gyn], [])), ['Gyn 504']);
});

test('a student unlock override beats the universal lock', () => {
  assert.deepEqual(names(resolveEffectiveCourseLocks([gyn], [{ ...gyn, locked: false }])), []);
});

test('a student lock override locks a module that is open for everyone', () => {
  assert.deepEqual(names(resolveEffectiveCourseLocks([], [{ ...peds, locked: true }])), ['Peds 505']);
});

test('notes: the student override note wins, else the universal note', () => {
  const [withUniversal] = resolveEffectiveCourseLocks([{ ...gyn, note: 'Everyone' }], []);
  assert.equal(withUniversal.note, 'Everyone');
  const [withOverride] = resolveEffectiveCourseLocks([{ ...gyn, note: 'Everyone' }], [{ ...gyn, locked: true, note: 'Pay first' }]);
  assert.equal(withOverride.note, 'Pay first');
});

test('locks on modules the reader cannot see are dropped', () => {
  assert.deepEqual(names(resolveEffectiveCourseLocks([{ course_id: 'c9', courses: null }], [])), []);
});
