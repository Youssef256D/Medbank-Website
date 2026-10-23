'use strict';

// Admin topics table: each topic shows whether students can see it.

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

const context = vm.createContext({
  getQbankCourseTopicMeta: (q) => ({ course: q.course, topic: q.topic }),
});
vm.runInContext(topLevelFunction('normalizeTopicKey'), context);
vm.runInContext(topLevelFunction('getCourseTopicStatusCounts'), context);
vm.runInContext(topLevelFunction('describeCourseTopicStatus'), context);

const statusFor = (questions, topic) => {
  const counts = context.getCourseTopicStatusCounts('Cardio', questions);
  const status = context.describeCourseTopicStatus(counts.get(context.normalizeTopicKey(topic)));
  return `${status.tone} | ${status.label} | ${status.detail}`;
};

const q = (topic, status, course = 'Cardio') => ({ course, topic, status });

test('all published, all draft, mixed and empty topics', () => {
  const questions = [
    q('ECG', 'published'), q('ECG', 'published'),
    q('Valves', 'draft'),
    q('Shock', 'published'), q('Shock', 'draft'), q('Shock', 'draft'),
    q('Empty', 'draft', 'Other course'),
  ];
  assert.strictEqual(statusFor(questions, 'ECG'), 'published | Published | 2 questions');
  assert.strictEqual(statusFor(questions, 'Valves'), 'draft | Draft | 1 question · hidden from students');
  assert.strictEqual(statusFor(questions, 'Shock'), 'mixed | Partly published | 1 of 3 published');
  assert.strictEqual(statusFor(questions, 'Empty'), 'empty | No questions | Hidden from students');
});

test('a question with no status counts as a draft', () => {
  assert.strictEqual(statusFor([{ course: 'Cardio', topic: 'ECG' }], 'ECG'), 'draft | Draft | 1 question · hidden from students');
});
