'use strict';

// The app_state backups of curriculum/topics/questions (g:mcq_*) stopped being
// written in June 2026, so they still hold courses, topics and questions that
// admins have since deleted. The admin backup restore must only use them when
// the relational DB read succeeded and returned nothing; otherwise every
// deleted course came back on the next admin load.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const start = mainSource.indexOf(`\nfunction ${name}(`) >= 0
    ? mainSource.indexOf(`\nfunction ${name}(`)
    : mainSource.indexOf(`\nasync function ${name}(`);
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return mainSource.slice(start, end) + '\n}\n';
};

const STALE_BACKUP = { 2: { 1: ['CVS', 'RES', 'MSS'] } };
const CURRENT = { 2: { 1: ['MSS'] } };

function harness(counts) {
  const store = { curriculum: CURRENT, topics: {}, questions: [] };
  const saved = [];
  const context = vm.createContext({
    STORAGE_KEYS: { curriculum: 'curriculum', courseTopics: 'topics', questions: 'questions' },
    MEDBANK_CURRICULUM: CURRENT,
    COURSE_TOPIC_OVERRIDES: {},
    adminBackupRestoreLastCheckedAt: 0,
    ADMIN_BACKUP_RESTORE_CHECK_COOLDOWN_MS: 0,
    Date,
    getCurrentUser: () => ({ role: 'admin' }),
    fetchSupabaseBackupPayloads: async () => ({
      curriculum: STALE_BACKUP,
      topics: { CVS: ['Heart'] },
      questions: [{ id: 'old-q' }],
    }),
    fetchRelationalContentCountsForRestore: async () => counts,
    load: (key, fallback) => (key in store ? store[key] : fallback),
    saveLocalOnly: (key, value) => { store[key] = value; saved.push(key); },
    save: (key) => { saved.push(`save:${key}`); },
    mergeCurriculumWithBackup: (local, backup) => ({ 2: { 1: [...new Set([...backup[2][1], ...local[2][1]])] } }),
    hasCurriculumAdditions: (base, next) => next[2][1].length > base[2][1].length,
    mergeCourseTopicMapWithBackup: (local, backup) => ({ ...backup, ...local }),
    hasCourseTopicAdditions: (base, next) => Object.keys(next).length > Object.keys(base).length,
    getQuestions: () => store.questions,
    dedupeQuestions: (list) => list,
    rehydrateCourseCatalogConfigFromStorage: () => {},
    repairCourseTopicCatalogFromQuestions: () => ({}),
    flushPendingSyncNow: async () => {},
    console,
  });
  ['isRelationalContentConfirmedEmpty', 'restoreAdminContentFromSupabaseBackupIfNeeded']
    .forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return { context, store, saved };
}

test('a stale backup does not bring back deleted courses, topics or questions', async () => {
  const { context, store, saved } = harness({ courseCount: 1, topicCount: 36, questionCount: 1531 });
  const result = await context.restoreAdminContentFromSupabaseBackupIfNeeded({ force: true });
  assert.strictEqual(result.restored, false);
  assert.deepStrictEqual(store.curriculum, CURRENT);
  assert.deepStrictEqual(saved, []);
});

test('a failed DB count read is not treated as an empty DB', async () => {
  const { context, saved } = harness(null);
  const result = await context.restoreAdminContentFromSupabaseBackupIfNeeded({ force: true });
  assert.strictEqual(result.restored, false);
  assert.deepStrictEqual(saved, []);
});

test('an empty DB is still recovered from the backup', async () => {
  const { context, store } = harness({ courseCount: 0, topicCount: 0, questionCount: 0 });
  const result = await context.restoreAdminContentFromSupabaseBackupIfNeeded({ force: true });
  assert.strictEqual(result.restored, true);
  assert.deepStrictEqual([...store.curriculum[2][1]], ['CVS', 'RES', 'MSS']);
});
