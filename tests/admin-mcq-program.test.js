'use strict';

// The site keeps MCQ subjects, topics and questions by NAME, one college at a
// time. These pin down which college that is for each role, that a save never
// writes one college's cached list into another, and that only the default
// college (October 6 University · Medicine) falls back to the built-in subject
// list for an empty term.

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

const DEFAULT_ID = '1ace4225-83d4-462c-8896-5186c93ccff9';
const OTHER_ID = '99a669ee-9d55-43ce-a507-6fb993420bb2';
const STUDENT_PROGRAM_ID = '2b4f8c1e-1111-4222-8333-944455556666';

function harness({ user = null, storage = {}, programRows = {} } = {}) {
  const store = { ...storage };
  const context = vm.createContext({
    window: {
      localStorage: {
        getItem: (key) => (key in store ? store[key] : null),
        setItem: (key, value) => { store[key] = String(value); },
        removeItem: (key) => { delete store[key]; },
      },
    },
    JSON,
    Date,
    Number,
    String,
    Boolean,
    Error,
    Promise,
    Map,
    Set,
    universityCollegesTableMissing: false,
    SUPABASE_QUERY_TIMEOUT_MS: 5000,
    DEFAULT_MEDBANK_CURRICULUM: { 1: { 1: ['Anatomy'], 2: ['Physiology'] }, 2: { 1: [], 2: [] }, 3: { 1: [], 2: [] }, 4: { 1: [], 2: [] }, 5: { 1: [], 2: [] } },
    getCurrentUser: () => user,
    isUuidValue: (value) => /^[0-9a-f-]{36}$/i.test(String(value || '')),
    normalizeUniversityIdValue: (value) => (value ? String(value).toLowerCase() : null),
    normalizeCollegeValue: (value) => (value ? String(value).toLowerCase() : null),
    resolveProgramIdForUniversityCollege: async () => STUDENT_PROGRAM_ID,
    getKnownCollegePrograms: () => Object.entries(programRows).map(([id, row]) => ({ id, ...row })),
    getRelationalClient: () => null,
    runWithTimeoutResult: async (promise) => promise,
    sanitizeCurriculumCourseList: (list) => [...new Set((list || []).map((e) => String(e).trim()).filter(Boolean))],
  });
  vm.runInContext(`
    const ADMIN_MCQ_PROGRAM_STORAGE_KEY = "medbank_admin_mcq_program";
    const MCQ_LOCAL_PROGRAM_STORAGE_KEY = "medbank_mcq_local_program_id";
    const WEBSITE_MCQ_PROGRAM_MISMATCH_ERROR_MESSAGE = "mismatch";
    let adminMcqProgramSelectionMemory;
    let mcqScopeUserMemo = null;
    let studentMcqProgramShape = null;
    const mcqProgramTermCountCache = new Map();
    async function getDefaultWebsiteMcqProgramId() { return "${DEFAULT_ID}"; }
  `, context);
  [
    'readMcqScopeStorage', 'writeMcqScopeStorage', 'clampMcqTermCount',
    'normalizeAdminMcqProgramSelection', 'readAdminMcqProgramSelection',
    'setAdminMcqProgramSelection', 'getCurrentUserRoleForMcqScope',
    'getAdminMcqProgramSelection', 'loadMcqProgramTermCounts',
    'rememberStudentMcqProgramShape', 'getMcqCurriculumShape',
    'isDefaultMcqCurriculumScope', 'getLocalMcqProgramMarker',
    'setLocalMcqProgramMarker', 'assertLocalMcqProgramMatches',
    'getWebsiteMcqProgramId', 'normalizeCurriculum',
    'sanitizeAcademicYear', 'sanitizeAcademicSemester',
    'normalizeAcademicYearOrNull', 'normalizeAcademicSemesterOrNull',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return { context, store };
}

test('an admin works on the default college until they pick another', async () => {
  const { context } = harness({ user: { role: 'admin' } });
  assert.strictEqual(await context.getWebsiteMcqProgramId(), DEFAULT_ID);
  assert.strictEqual(context.isDefaultMcqCurriculumScope(), true);
});

test("an admin's picked college is the scope, with its own years and semesters", async () => {
  const { context, store } = harness({ user: { role: 'admin' } });
  context.setAdminMcqProgramSelection({ id: OTHER_ID, years: 6, semesters: 3 });
  assert.strictEqual(await context.getWebsiteMcqProgramId(), OTHER_ID);
  assert.ok(store.medbank_admin_mcq_program.includes(OTHER_ID));
  const shape = context.getMcqCurriculumShape();
  assert.strictEqual(shape.years, 6);
  assert.strictEqual(shape.semesters, 3);
  assert.strictEqual(shape.useDefaults, false);
});

test("a student's scope is their own college, never the admin's pick", async () => {
  const { context } = harness({
    user: { role: 'student', universityId: 'u1', college: 'dentistry' },
    storage: { medbank_admin_mcq_program: JSON.stringify({ id: OTHER_ID, years: 5, semesters: 2 }) },
    programRows: { [STUDENT_PROGRAM_ID]: { years_count: 6, semesters_per_year: 2 } },
  });
  assert.strictEqual(await context.getWebsiteMcqProgramId(), STUDENT_PROGRAM_ID);
  const shape = context.getMcqCurriculumShape();
  assert.strictEqual(shape.years, 6);
  assert.strictEqual(shape.useDefaults, false);
});

test('a save is refused when the cached subjects belong to another college', () => {
  const { context, store } = harness({ user: { role: 'admin' } });
  // First run after the change: the cache is adopted by the current college.
  context.assertLocalMcqProgramMatches(DEFAULT_ID);
  assert.strictEqual(store.medbank_mcq_local_program_id, DEFAULT_ID);
  context.assertLocalMcqProgramMatches(DEFAULT_ID);
  assert.throws(() => context.assertLocalMcqProgramMatches(OTHER_ID), /mismatch/);
});

test('only the default college fills an empty term with the built-in subjects', () => {
  const admin = harness({ user: { role: 'admin' } });
  const filled = admin.context.normalizeCurriculum({ 1: { 1: [], 2: [] } });
  assert.deepStrictEqual([...filled[1][1]], ['Anatomy']);

  const other = harness({ user: { role: 'admin' } });
  other.context.setAdminMcqProgramSelection({ id: OTHER_ID, years: 6, semesters: 2 });
  const empty = other.context.normalizeCurriculum({ 1: { 1: [], 2: [] } });
  assert.deepStrictEqual([...empty[1][1]], []);
  assert.deepStrictEqual(Object.keys(empty), ['1', '2', '3', '4', '5', '6']);
});

test('years go to 7 and semesters to 3, as the database allows', () => {
  const { context } = harness();
  assert.strictEqual(context.sanitizeAcademicYear(6), 6);
  assert.strictEqual(context.sanitizeAcademicYear(7), 7);
  assert.strictEqual(context.sanitizeAcademicYear(8), 1);
  assert.strictEqual(context.sanitizeAcademicSemester(3), 3);
  assert.strictEqual(context.sanitizeAcademicSemester(4), 1);
});
