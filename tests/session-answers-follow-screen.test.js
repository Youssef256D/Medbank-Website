'use strict';

// A question answered on the website came back unanswered after the student
// moved past it. Every click on the test page first reads the ticked choices
// on screen into the session's current question. A cloud merge or a
// shared-test pull can move that currentIndex without redrawing, so the
// screen's (often empty) choices were written into a different question.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const from = mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', from);
  assert.ok(from >= 0 && end > from, `main.js function moved: ${name}`);
  return mainSource.slice(from, end) + '\n}\n';
};

// The page as renderSession leaves it: one .exam-answers block naming the
// session and question it shows, and the radio inputs ticked on screen.
function fakePage({ sessionId, questionId, checked }) {
  const answers = questionId == null ? null : {
    getAttribute: (name) => ({ 'data-session-id': sessionId, 'data-question-id': questionId })[name] ?? null,
  };
  return {
    querySelector: (selector) => (selector.startsWith('.exam-answers') ? answers : null),
    querySelectorAll: () => checked.map((value) => ({ value })),
  };
}

function load(appEl) {
  const context = vm.createContext({ appEl, resolveSessionQuestionId: (qid) => qid });
  vm.runInContext([
    topLevelFunction('getCurrentSessionResponseContext'),
    topLevelFunction('getRenderedSessionQuestionIndex'),
    topLevelFunction('syncActiveResponseSelectionFromDom'),
  ].join('\n'), context);
  return context;
}

function session(currentIndex) {
  return {
    id: 'session-1',
    questionIds: ['q1', 'q2', 'q3'],
    currentIndex,
    responses: {
      q1: { selected: ['B'], submitted: true },
      q2: { selected: [], submitted: false },
      q3: { selected: ['D'], submitted: true },
    },
  };
}

test('a background move of currentIndex does not wipe the question it points at', () => {
  // On screen: question 2, nothing ticked. The store was moved back to 1.
  const s = session(0);
  const { syncActiveResponseSelectionFromDom } = load(fakePage({ sessionId: 'session-1', questionId: 'q2', checked: [] }));
  syncActiveResponseSelectionFromDom(s);
  assert.deepStrictEqual(s.responses.q1.selected, ['B']);
  assert.strictEqual(s.responses.q1.submitted, true);
  assert.strictEqual(s.currentIndex, 1, 'the session follows the question on screen');
});

test('the choice on screen is saved to the question on screen', () => {
  const s = session(2);
  const { syncActiveResponseSelectionFromDom } = load(fakePage({ sessionId: 'session-1', questionId: 'q2', checked: ['c'] }));
  syncActiveResponseSelectionFromDom(s);
  assert.deepStrictEqual([...s.responses.q2.selected], ['C']);
  assert.deepStrictEqual(s.responses.q3.selected, ['D']);
});

test('nothing is written when the page shows no question of this session', () => {
  for (const page of [
    fakePage({ sessionId: 'session-1', questionId: null, checked: [] }),
    fakePage({ sessionId: 'other-session', questionId: 'q1', checked: [] }),
    fakePage({ sessionId: 'session-1', questionId: 'gone', checked: [] }),
  ]) {
    const s = session(0);
    load(page).syncActiveResponseSelectionFromDom(s);
    assert.deepStrictEqual(s.responses.q1.selected, ['B']);
    assert.strictEqual(s.currentIndex, 0);
  }
});
