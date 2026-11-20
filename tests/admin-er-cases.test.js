'use strict';

// The website's ER Shift case checker (validateErCase) must agree with the
// app's ErCaseValidator: the guided case passes, and a case that does not
// test doctor skills is refused. tests/fixtures/er-guided-case.json is a copy
// of the app's assets/er_shift/cases/tutorial-anterior-stemi.json.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const start = mainSource.indexOf('const ER_TUTORIAL_CASE_ID');
const end = mainSource.indexOf('\nfunction buildErCasePrompt(', start);
assert.ok(start >= 0 && end > start, 'main.js markers moved');
const context = {};
vm.runInNewContext(`${mainSource.slice(start, end)}\nthis.validateErCase = validateErCase; this.parseErCasesJson = parseErCasesJson;`, context);
const { validateErCase, parseErCasesJson } = context;

const guided = () => {
  const c = JSON.parse(fs.readFileSync('tests/fixtures/er-guided-case.json', 'utf8'));
  delete c.tutorial;
  return { ...c, id: 'copy-of-guided' };
};

test('the guided case, as a new case, passes', () => {
  assert.deepEqual(Array.from(validateErCase(guided())), []);
});

test('the guided case id itself is refused', () => {
  const c = { ...guided(), id: 'tutorial-anterior-stemi' };
  assert.ok(validateErCase(c).some((p) => p.startsWith('id: the guided case')));
});

test('a case without doctor-skill steps is refused', () => {
  const c = guided();
  c.steps = c.steps.filter((s) => !s.id.startsWith('sk_'));
  assert.ok(validateErCase(c).some((p) => p.startsWith('steps: at least 2 doctor-skill steps')));
});

test('a skill step is never critical, and its skill must be known', () => {
  const c = guided();
  c.steps.push(
    { id: 'sk_a', label: 'Talk', kind: 'critical', skill: 'communication', why: 'Long enough to teach something.' },
    { id: 'sk_b', label: 'Hum', kind: 'must', skill: 'singing', why: 'Long enough to teach something.' },
  );
  const problems = validateErCase(c);
  assert.ok(problems.some((p) => p.startsWith('step sk_a: a skill step is')));
  assert.ok(problems.some((p) => p.startsWith('step sk_b: skill one of')));
});

test('reads what an AI answers: fenced, a list, or {"cases": [...]}', () => {
  const one = JSON.stringify(guided());
  assert.equal(parseErCasesJson('```json\n[' + one + ']\n```').length, 1);
  assert.equal(parseErCasesJson(`{"cases": [${one}, ${one}]}`).length, 2);
  assert.equal(parseErCasesJson(one).length, 1);
  assert.throws(() => parseErCasesJson('not json'));
});
