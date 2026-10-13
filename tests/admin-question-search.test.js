'use strict';

// Admin > Questions search: every word must match the stem, an option, the
// explanation or the ID. The same filter feeds the table, select-all and the
// bulk actions (getVisibleAdminQuestions), so they never disagree.

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

const context = vm.createContext({});
vm.runInContext(topLevelFunction('filterAdminQuestionsBySearch'), context);
const search = (list, query) => context.filterAdminQuestionsBySearch(list, query).map((q) => q.id);

const QUESTIONS = [
  { id: 'q1', stem: 'Which nerve supplies the deltoid?', choices: [{ id: 'A', text: 'Axillary' }], explanation: 'C5-C6 root' },
  { id: 'q2', stem: 'Main inspiratory muscle?', choices: [{ id: 'A', text: 'Diaphragm' }], explanation: 'Phrenic NERVE' },
  { id: 'q3', stem: 'Bone of the thigh?', choices: [{ id: 'A', text: 'Femur' }] },
];

test('empty query keeps every question', () => {
  assert.deepStrictEqual(search(QUESTIONS, '   '), ['q1', 'q2', 'q3']);
});

test('matches stem, options, explanation and ID, case-insensitively', () => {
  assert.deepStrictEqual(search(QUESTIONS, 'nerve'), ['q1', 'q2']);
  assert.deepStrictEqual(search(QUESTIONS, 'femur'), ['q3']);
  assert.deepStrictEqual(search(QUESTIONS, 'c5-c6'), ['q1']);
  assert.deepStrictEqual(search(QUESTIONS, 'Q2'), ['q2']);
});

test('every word must match', () => {
  assert.deepStrictEqual(search(QUESTIONS, 'nerve deltoid'), ['q1']);
  assert.deepStrictEqual(search(QUESTIONS, 'nerve femur'), []);
});

test('the select-all / bulk list uses the same search', () => {
  assert.match(mainSource, /return filterAdminQuestionsBySearch\(resolvedView\.filteredQuestions, state\.adminQuestionSearch\);/);
});
