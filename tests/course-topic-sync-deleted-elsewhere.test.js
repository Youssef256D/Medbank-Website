'use strict';

// A stale admin tab still listing a deleted topic must not re-create it.
// Only topics this browser never saw in the DB (added here) may be created or
// reactivated (2026-10-15: Gyn 504 got 13 deleted topics back from an old tab).

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
    STORAGE_KEYS: { courseTopicDbSnapshot: 'snapshot', courseTopics: 'topics' },
    COURSE_TOPIC_OVERRIDES: {},
    store,
    load: (key, fallback) => (key in store ? JSON.parse(JSON.stringify(store[key])) : fallback),
    saveLocalOnly: (key, value) => { store[key] = JSON.parse(JSON.stringify(value)); },
    normalizeTopicKey: (topic) => String(topic || '').trim().toLowerCase(),
    normalizeCourseTopicList: (topics) => (topics.length ? topics : ['Clinical Applications']),
    rebuildCurriculumCatalog: () => {},
  });
  [
    'courseTopicSnapshotKey',
    'getCourseTopicDbSnapshot',
    'saveCourseTopicDbSnapshot',
    'selectTopicsNeedingUpsert',
    'removeLocalCourseTopicsDeletedElsewhere',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return context;
}

const GYN = 'course-gyn';
const courses = [{ id: GYN, course_name: 'Gyn 504', is_active: true }];
const courseNameById = { [GYN]: 'Gyn 504' };
const desired = (name, sortOrder) => ({ course_id: GYN, topic_name: name, sort_order: sortOrder, is_active: true });
const row = (name, sortOrder, isActive) => ({ id: name, course_id: GYN, topic_name: name, sort_order: sortOrder, is_active: isActive });
const byKey = (rows) => Object.fromEntries(rows.map((topic) => [`${topic.course_id}::${topic.topic_name}`, topic]));
const names = (rows) => Array.from(rows, (topic) => topic.topic_name);

test('a topic this browser saw in the DB, now gone, is not re-created', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot(courses, [row('Basic Gynecology', 1, true), row('Contraception', 2, true)]);
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('Basic Gynecology', 1), desired('Contraception', 2)],
    byKey([row('Contraception', 2, true)]),
    courseNameById,
    ctx.getCourseTopicDbSnapshot(),
  );
  assert.deepStrictEqual(names(result.upserts), []);
  assert.deepStrictEqual(Array.from(result.deletedElsewhere, (entry) => entry.topicName), ['Basic Gynecology']);
});

test('a soft-deleted topic seen before is not reactivated', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot(courses, [row('Infertility', 1, true)]);
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('Infertility', 1)],
    byKey([row('Infertility', 1, false)]),
    courseNameById,
    ctx.getCourseTopicDbSnapshot(),
  );
  assert.deepStrictEqual(names(result.upserts), []);
});

test('a topic added in this browser is still created', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot(courses, [row('Contraception', 1, true)]);
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('Contraception', 1), desired('Puberty', 2)],
    byKey([row('Contraception', 1, true)]),
    courseNameById,
    ctx.getCourseTopicDbSnapshot(),
  );
  assert.deepStrictEqual(names(result.upserts), ['Puberty']);
});

test('a re-added topic whose old row is inactive is reactivated once the snapshot dropped it', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot(courses, [row('Puberty', 1, false)]);
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('Puberty', 1)],
    byKey([row('Puberty', 1, false)]),
    courseNameById,
    ctx.getCourseTopicDbSnapshot(),
  );
  assert.deepStrictEqual(names(result.upserts), ['Puberty']);
});

test('active topics only upsert when their order changed', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot(courses, [row('A', 1, true), row('B', 2, true)]);
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('A', 1), desired('B', 3)],
    byKey([row('A', 1, true), row('B', 2, true)]),
    courseNameById,
    ctx.getCourseTopicDbSnapshot(),
  );
  assert.deepStrictEqual(names(result.upserts), ['B']);
});

test('without a snapshot, missing rows are created but inactive rows stay off', () => {
  const ctx = harness();
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('New', 1), desired('Old', 2)],
    byKey([row('Old', 2, false)]),
    courseNameById,
    null,
  );
  assert.deepStrictEqual(names(result.upserts), ['New']);
});

test('refused topics stay in the snapshot and leave the local topic map', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot(courses, [row('Contraception', 1, true)], ['Gyn 504::basic gynecology']);
  assert.ok(ctx.getCourseTopicDbSnapshot().has('Gyn 504::basic gynecology'));
  vm.runInContext("COURSE_TOPIC_OVERRIDES = { 'Gyn 504': ['Basic Gynecology', 'Contraception'] };", ctx);
  assert.strictEqual(ctx.removeLocalCourseTopicsDeletedElsewhere([{ courseName: 'Gyn 504', topicName: 'Basic Gynecology' }]), true);
  assert.deepStrictEqual(ctx.store.topics, { 'Gyn 504': ['Contraception'] });
});

test('topics of inactive courses are not recorded', () => {
  const ctx = harness();
  ctx.saveCourseTopicDbSnapshot([{ id: GYN, course_name: 'Gyn 504', is_active: false }], [row('A', 1, true)]);
  assert.strictEqual(ctx.getCourseTopicDbSnapshot().size, 0);
});

test('first run seeds the snapshot from the saved local topics only once', () => {
  const ctx = harness();
  vm.runInContext(topLevelFunction('seedCourseTopicDbSnapshotFromLocal'), ctx);
  ctx.seedCourseTopicDbSnapshotFromLocal({ 'Gyn 504': ['Basic Gynecology', ''] });
  assert.deepStrictEqual(Array.from(ctx.getCourseTopicDbSnapshot()), ['Gyn 504::basic gynecology']);
  ctx.seedCourseTopicDbSnapshotFromLocal({ 'Gyn 504': ['Puberty'] });
  assert.deepStrictEqual(Array.from(ctx.getCourseTopicDbSnapshot()), ['Gyn 504::basic gynecology']);
  const result = ctx.selectTopicsNeedingUpsert(
    [desired('Basic Gynecology', 1)], byKey([]), courseNameById, ctx.getCourseTopicDbSnapshot(),
  );
  assert.deepStrictEqual(names(result.upserts), []);
});
