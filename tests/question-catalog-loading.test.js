'use strict';

// The admin never downloads the whole question bank: the Questions page loads
// the course it shows. Students still download every question they can read
// (Create Test needs all of it), paged by id instead of by offset. A failed
// load is said on screen, with Retry, instead of quietly keeping an old copy.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const asyncStart = mainSource.indexOf(`\nasync function ${name}(`);
  const start = asyncStart >= 0 ? asyncStart : mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return mainSource.slice(start, end) + '\n}\n';
};

// Arrays made inside the vm context are not this realm's arrays.
const plain = (value) => JSON.parse(JSON.stringify(value));
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

const makeContext = (extra = {}) => {
  const context = vm.createContext({
    SUPABASE_QUERY_TIMEOUT_MS: 1000,
    QUESTION_RELATIONAL_TIMEOUT_MS: 1000,
    QUESTION_RELATIONAL_PAGE_SIZE: 2,
    ADMIN_QUESTION_BACKGROUND_REFRESH_MS: 180000,
    ADMIN_COURSE_QUESTION_BUSY_RETRY_MS: 2000,
    QUESTION_HYDRATION_BUSY_MESSAGE: 'Saving your changes first.',
    STORAGE_KEYS: { questions: 'questions' },
    runWithTimeoutResult: (promise) => Promise.resolve(promise),
    escapeHtml: (value) => String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;'),
    getQbankCourseTopicMeta: (q) => ({ course: q.qbankCourse || q.course || '', topic: q.qbankTopic || q.topic || '' }),
    console: { warn: () => {} },
    ...extra,
  });
  [
    'normalizeQuestionSortOrder',
    'normalizeAdminQuestionFilterToken',
    'isUuidValue',
    'toRelationalQuestionStatus',
    'compareQuestionsBySortOrder',
    'fetchRowsByKeyset',
    'fetchAdminCourseQuestionRows',
    'mergeCourseScopedQuestions',
    'assignQuestionSortOrdersForSync',
    'applyReorderedQuestionPositions',
    'shouldLoadAdminCourseQuestions',
    'renderQuestionLoadNotice',
    'renderAdminCourseQuestionLoadNotice',
    'renderStudentQuestionReadNotice',
  ].forEach((name) => vm.runInContext(topLevelFunction(name), context));
  return context;
};

// A fake paged source: rows sorted by id, read `after` an id.
const keysetSource = (rows, { failOnCall = -1 } = {}) => {
  const calls = [];
  const fetchPage = (afterId, limit) => {
    calls.push(afterId);
    if (calls.length - 1 === failOnCall) {
      return Promise.resolve({ data: null, error: new Error('page failed') });
    }
    const page = rows.filter((row) => afterId === null || row.id > afterId).slice(0, limit);
    return Promise.resolve({ data: page, error: null });
  };
  return { fetchPage, calls };
};

test('the download pages by the last id, so rows added mid-download cannot shift a page', async () => {
  const context = makeContext();
  const rows = [{ id: uuid(1) }, { id: uuid(2) }, { id: uuid(3) }, { id: uuid(4) }, { id: uuid(5) }];
  const { fetchPage, calls } = keysetSource(rows);
  const result = await context.fetchRowsByKeyset(fetchPage, { pageSize: 2 });
  assert.strictEqual(result.error, null);
  assert.deepStrictEqual(plain(result.data.map((row) => row.id)), rows.map((row) => row.id));
  assert.deepStrictEqual(calls, [null, uuid(2), uuid(4)]);
});

test('one failed page fails the whole load: no partial question set', async () => {
  const context = makeContext();
  const rows = [{ id: uuid(1) }, { id: uuid(2) }, { id: uuid(3) }];
  const { fetchPage } = keysetSource(rows, { failOnCall: 1 });
  const result = await context.fetchRowsByKeyset(fetchPage, { pageSize: 2 });
  assert.strictEqual(result.data, null);
  assert.match(result.error.message, /page failed/);
});

test('a source whose ids do not advance stops instead of looping', async () => {
  const context = makeContext();
  const fetchPage = () => Promise.resolve({ data: [{ id: uuid(1) }, { id: uuid(1) }], error: null });
  const result = await context.fetchRowsByKeyset(fetchPage, { pageSize: 2 });
  assert.strictEqual(result.data, null);
  assert.match(result.error.message, /stopped advancing/);
});

test('an admin course load asks the database for that course only, choices embedded', async () => {
  const queries = [];
  const client = {
    from: (table) => {
      const query = { table, filters: [] };
      queries.push(query);
      const builder = {
        select: (columns) => { query.columns = columns; return builder; },
        eq: (column, value) => { query.filters.push(['eq', column, value]); return builder; },
        in: (column, value) => { query.filters.push(['in', column, value]); return builder; },
        gt: (column, value) => { query.filters.push(['gt', column, value]); return builder; },
        order: () => builder,
        limit: () => builder,
        then: (resolve, reject) => {
          const data = table === 'courses'
            ? [{ id: uuid(90), course_name: 'Pharmacology' }]
            : [{ id: uuid(1), stem: 'Q1', choices: [] }];
          return Promise.resolve({ data, error: null }).then(resolve, reject);
        },
      };
      return builder;
    },
  };
  const context = makeContext();
  const result = await context.fetchAdminCourseQuestionRows(client, 'Pharmacology', { sortOrder: true });
  assert.strictEqual(result.error, null);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(result.data)), [{ id: uuid(1), stem: 'Q1', choices: [], course_name: 'Pharmacology' }]);
  const questionsQuery = queries.find((q) => q.table === 'questions');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(questionsQuery.filters)), [['in', 'course_id', [uuid(90)]]]);
  assert.match(questionsQuery.columns, /choices:question_choices\(/);
  assert.match(questionsQuery.columns, /sort_order/);
});

test('loading one course replaces that course and leaves every other course untouched', () => {
  const context = makeContext();
  const local = [
    { id: 'a1', dbId: uuid(1), qbankCourse: 'Anatomy', stem: 'A1', sortOrder: 5 },
    { id: 'p1', dbId: uuid(11), qbankCourse: 'Pharmacology', stem: 'old text', sortOrder: 40 },
    { id: 'p2', dbId: uuid(12), qbankCourse: 'Pharmacology', stem: 'deleted elsewhere', sortOrder: 41 },
    { id: 'p-new', qbankCourse: 'Pharmacology', stem: 'new, still saving' },
    { id: 'moved', dbId: uuid(13), qbankCourse: 'Anatomy', stem: 'moved to Pharmacology elsewhere', sortOrder: 6 },
    { id: 'a2', dbId: uuid(2), qbankCourse: 'Anatomy', stem: 'A2', sortOrder: 7 },
  ];
  const remote = [
    { id: 'moved', dbId: uuid(13), qbankCourse: 'Pharmacology', stem: 'moved', sortOrder: 39 },
    { id: 'p1', dbId: uuid(11), qbankCourse: 'Pharmacology', stem: 'new text', sortOrder: 40 },
  ];
  const merged = context.mergeCourseScopedQuestions(local, remote, { courseKey: 'pharmacology', pendingDeletionIds: [] });
  assert.deepStrictEqual(plain(merged.questions.map((q) => q.id)), ['a1', 'a2', 'moved', 'p1', 'p-new']);
  assert.strictEqual(merged.questions.find((q) => q.id === 'p1').stem, 'new text');
  assert.strictEqual(merged.questions[0], local[0], 'other courses keep the same objects');
  assert.deepStrictEqual(plain([...merged.replacedExternalIds].sort()), ['moved', 'p-new', 'p1', 'p2']);
  assert.strictEqual(merged.scopeCount, 3);
});

test('a new question still saving is dropped if it was queued for deletion', () => {
  const context = makeContext();
  const local = [{ id: 'gone', qbankCourse: 'Pharmacology', stem: 'x' }];
  const merged = context.mergeCourseScopedQuestions(local, [], { courseKey: 'pharmacology', pendingDeletionIds: ['gone'] });
  assert.deepStrictEqual(plain(merged.questions), []);
});

test('saving keeps each question at its position; only a new one is placed, after the whole bank', () => {
  const context = makeContext();
  const questions = [
    { id: 'p1', sortOrder: 40 },
    { id: 'new1' },
    { id: 'p2', sortOrder: 41 },
    { id: 'new2' },
  ];
  const map = context.assignQuestionSortOrdersForSync(questions, 23875);
  assert.deepStrictEqual(plain([...map.entries()]), [['p1', 40], ['new1', 23876], ['p2', 41], ['new2', 23877]]);
  // Without the server's highest position, it still goes after the local ones.
  const offline = context.assignQuestionSortOrdersForSync(questions, 0);
  assert.strictEqual(offline.get('new1'), 42);
});

test('reordering swaps positions among the moved questions only', () => {
  const context = makeContext();
  const questions = [
    { id: 'a1', sortOrder: 5 },
    { id: 'p1', sortOrder: 40 },
    { id: 'p2', sortOrder: 40 },
    { id: 'p3', sortOrder: 52 },
  ];
  // The admin dragged p3 to the top of Pharmacology. The tie at 40 (left by
  // an import) becomes 40, 41 so the new order holds.
  const reordered = [questions[3], questions[1], questions[2]];
  const next = context.applyReorderedQuestionPositions(questions, reordered);
  assert.deepStrictEqual(plain(next.map((q) => `${q.id}:${q.sortOrder}`)), ['a1:5', 'p1:41', 'p2:52', 'p3:40']);
  assert.strictEqual(next[0], questions[0], 'a question outside the move is not rewritten');
});

test('reordering questions with no positions yet falls back to numbering the list', () => {
  const context = makeContext();
  const questions = [{ id: 'a' }, { id: 'b', sortOrder: 3 }];
  const next = context.applyReorderedQuestionPositions(questions, [questions[1], questions[0]]);
  assert.deepStrictEqual(plain(next.map((q) => q.sortOrder)), [1, 2]);
});

test('a course loads when first shown and again after three minutes, never while failed', () => {
  const context = makeContext();
  const now = 1_000_000;
  assert.strictEqual(context.shouldLoadAdminCourseQuestions(null, now), true);
  assert.strictEqual(context.shouldLoadAdminCourseQuestions({ status: 'loading', loadedAt: 0 }, now), false);
  assert.strictEqual(context.shouldLoadAdminCourseQuestions({ status: 'loaded', loadedAt: now - 1000 }, now), false);
  assert.strictEqual(context.shouldLoadAdminCourseQuestions({ status: 'loaded', loadedAt: now - 180001 }, now), true);
  assert.strictEqual(context.shouldLoadAdminCourseQuestions({ status: 'loaded', loadedAt: 0 }, now), true, 'marked stale');
  assert.strictEqual(context.shouldLoadAdminCourseQuestions({ status: 'failed', loadedAt: 0 }, now), false, 'waits for Retry');
  assert.strictEqual(context.shouldLoadAdminCourseQuestions({ status: 'waiting', loadedAt: 0 }, now), false);
});

test('the Questions page says when a course failed to load, with Retry', () => {
  const context = makeContext();
  assert.strictEqual(context.renderAdminCourseQuestionLoadNotice('NRS', { status: 'loaded', loadedAt: 1 }), '');
  assert.strictEqual(context.renderAdminCourseQuestionLoadNotice('NRS', null), '');
  const neverLoaded = context.renderAdminCourseQuestionLoadNotice('NRS', { status: 'failed', loadedAt: 0, error: 'timed out' });
  assert.match(neverLoaded, /Couldn't load the NRS questions, so none are shown/);
  assert.match(neverLoaded, /timed out/);
  assert.match(neverLoaded, /data-action="admin-retry-course-questions" data-course="NRS"/);
  const stale = context.renderAdminCourseQuestionLoadNotice('NRS', { status: 'failed', loadedAt: 5, error: '' });
  assert.match(stale, /may be out of date/);
  const waiting = context.renderAdminCourseQuestionLoadNotice('NRS', { status: 'waiting', loadedAt: 0, error: '' });
  assert.match(waiting, /Saving your changes first/);
  assert.doesNotMatch(waiting, /Retry/);
});

test("Create Test says when the student's question download failed", () => {
  const context = makeContext();
  assert.strictEqual(context.renderStudentQuestionReadNotice({ status: 'success', error: '' }), '');
  assert.strictEqual(context.renderStudentQuestionReadNotice({ status: 'loading', error: '' }), '');
  const failed = context.renderStudentQuestionReadNotice({ status: 'error', error: 'Question hydration timed out.' });
  assert.match(failed, /new questions may be missing/);
  assert.match(failed, /data-action="refresh-student-analytics"/);
  assert.ok(mainSource.includes('$' + '{renderStudentQuestionReadNotice()}'), 'Create Test renders it');
});

const loadContext = ({ hydrate, busy = () => false }) => {
  const renders = [];
  const timers = [];
  const context = makeContext({
    state: { route: 'admin', adminPage: 'questions', adminQuestionModalOpen: false, adminFilters: { course: 'NRS' } },
    relationalSync: { lastReadyError: '' },
    render: () => renders.push('render'),
    window: { setTimeout: (fn) => timers.push(fn) },
    ensureRelationalSyncReady: async () => true,
    isRelationalStorageKeyBusy: busy,
    isQuestionSyncBusy: () => false,
    flushPendingSyncNow: async () => {},
    hydrateRelationalQuestions: hydrate,
  });
  vm.runInContext(`
    const adminCourseQuestionLoads = new Map();
    const adminCourseQuestionLoadPromises = new Map();
    let lastQuestionHydrationError = "";
    globalThis.loads = adminCourseQuestionLoads;
    globalThis.setHydrationError = (message) => { lastQuestionHydrationError = message; };
  `, context);
  vm.runInContext(topLevelFunction('rerenderAdminQuestionsForCourse'), context);
  vm.runInContext(topLevelFunction('loadAdminCourseQuestions'), context);
  vm.runInContext(topLevelFunction('requestAdminCourseQuestions'), context);
  return { context, renders, timers };
};

test('a course load records success, and asks only for that course', async () => {
  const asked = [];
  const { context, renders } = loadContext({ hydrate: async (options) => { asked.push(options); return true; } });
  assert.strictEqual(await context.loadAdminCourseQuestions('NRS'), true);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(asked)), [{ courseName: 'NRS' }]);
  assert.strictEqual(context.loads.get('nrs').status, 'loaded');
  assert.ok(context.loads.get('nrs').loadedAt > 0);
  assert.strictEqual(renders.length, 1);
});

test('a failed course load is recorded with its reason, not hidden', async () => {
  const { context } = loadContext({ hydrate: async () => { context.setHydrationError('Question hydration timed out.'); return false; } });
  assert.strictEqual(await context.loadAdminCourseQuestions('NRS'), false);
  assert.deepStrictEqual(
    { status: context.loads.get('nrs').status, error: context.loads.get('nrs').error },
    { status: 'failed', error: 'Question hydration timed out.' },
  );
});

test('a load blocked by unsaved edits waits and tries again, instead of being skipped', async () => {
  const { context, timers } = loadContext({ hydrate: async () => { context.setHydrationError('Saving your changes first.'); return false; } });
  await context.loadAdminCourseQuestions('NRS');
  assert.strictEqual(context.loads.get('nrs').status, 'waiting');
  assert.strictEqual(timers.length, 1, 'a retry is scheduled');
});

test('two renders asking for the same course start one download', async () => {
  let calls = 0;
  const { context, timers } = loadContext({ hydrate: async () => { calls += 1; return true; } });
  assert.strictEqual(context.requestAdminCourseQuestions('NRS').status, 'loading');
  assert.strictEqual(context.requestAdminCourseQuestions('NRS').status, 'loading');
  assert.strictEqual(timers.length, 1);
  await timers[0]();
  await new Promise((resolve) => { setImmediate(resolve); });
  assert.strictEqual(calls, 1);
});

test('the admin data refresh no longer downloads the question bank', () => {
  const refresh = topLevelFunction('refreshAdminDataSnapshot');
  assert.doesNotMatch(refresh, /hydrateRelationalQuestions\(/);
  const relationalState = topLevelFunction('hydrateRelationalState');
  assert.match(relationalState, /current\?\.role !== "admin"\) \{\n\s+await hydrateRelationalQuestions\(\);/);
  // Students keep the full download, paged by id first.
  const hydrate = topLevelFunction('hydrateRelationalQuestions');
  assert.match(hydrate, /get_question_catalog_page_after/);
});
