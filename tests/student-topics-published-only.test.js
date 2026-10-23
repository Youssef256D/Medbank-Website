'use strict';

// Create Test: a student only sees topics that have at least one published
// question. A topic whose questions are all drafts is hidden, both in the
// flat list and inside a subgroup (and an emptied subgroup disappears).

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

const setup = ({ topics, groups = {} }) => {
  const context = vm.createContext({
    QBANK_COURSE_TOPICS: { Anatomy: topics },
    isRemovedTopicName: () => false,
    normalizeTopicLookupKey: (t) => String(t || '').trim().toLowerCase(),
    doCourseNamesMatch: (a, b) => a === b,
    getQbankCourseTopicMeta: (q) => ({ course: q.course, topic: q.topic }),
    getCourseTopicGroups: () => groups,
  });
  vm.runInContext(topLevelFunction('getAvailableTopicsForCourse'), context);
  vm.runInContext(topLevelFunction('getAvailableTopicSourceOptionsForCourse'), context);
  vm.runInContext(topLevelFunction('getAvailableTopicSectionsForCourse'), context);
  return context;
};

// Arrays built inside the vm context have another Array prototype.
const plain = (value) => JSON.parse(JSON.stringify(value));

// The page only ever passes published questions (getPublishedQuestionsForUser),
// so "Lower limb", whose questions are all drafts, has none here.
const PUBLISHED = [
  { course: 'Anatomy', topic: 'Upper limb' },
  { course: 'Anatomy', topic: 'Thorax' },
];

test('flat list keeps curriculum order and drops topics with no published questions', () => {
  const context = setup({ topics: ['Thorax', 'Lower limb', 'Upper limb'] });
  const sections = context.getAvailableTopicSectionsForCourse('Anatomy', PUBLISHED, {});
  assert.deepStrictEqual(plain(sections.map((s) => s.topics)), [['Thorax', 'Upper limb']]);
});

test('subgroups drop drafted topics, and a subgroup left empty disappears', () => {
  const context = setup({
    topics: ['Thorax', 'Lower limb', 'Upper limb'],
    groups: { Limbs: ['Upper limb', 'Lower limb'], Legs: ['Lower limb'], Trunk: ['Thorax'] },
  });
  const options = context.getAvailableTopicSourceOptionsForCourse('Anatomy', PUBLISHED);
  assert.deepStrictEqual(
    plain(options.map((o) => [o.label, o.topics])),
    [['Limbs', ['Upper limb']], ['Trunk', ['Thorax']]],
  );
});

test('a course with no published questions shows no topics', () => {
  const context = setup({ topics: ['Thorax', 'Lower limb'] });
  assert.deepStrictEqual(plain(context.getAvailableTopicsForCourse('Anatomy', [])), []);
});
