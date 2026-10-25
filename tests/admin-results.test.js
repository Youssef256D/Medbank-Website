const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const blockStart = mainSource.indexOf('// Admin Student results (People area).');
const blockEnd = mainSource.indexOf('window.__MCQ_ON_GSAP_READY__', blockStart);
assert.ok(blockStart >= 0 && blockEnd > blockStart, 'admin results block markers moved');

// The real helpers the block calls, sliced by name so the stubs never drift.
function sliceFunction(name) {
  const start = mainSource.indexOf(`\nfunction ${name}(`);
  assert.ok(start >= 0, `${name} not found`);
  const end = mainSource.indexOf('\n}\n', start);
  return mainSource.slice(start, end + 3);
}

function loadResults({ rpc } = {}) {
  const calls = [];
  const context = vm.createContext({
    Date, Number, Object, Array, String, Math, Map, Set, Intl, JSON, Promise, console,
    state: { route: 'admin', adminPage: 'results' },
    calls,
    appEl: { querySelector: () => null, querySelectorAll: () => [] },
    document: { activeElement: null, getElementById: () => null },
    window: { setTimeout, clearTimeout },
    render: () => {},
    applyAdminPageTransition: () => {},
    getRelationalClient: () => ({
      rpc: (name, params) => {
        calls.push({ name, params });
        return rpc ? rpc(name, params) : Promise.resolve({ data: null, error: null });
      },
      from: () => ({ select: () => Promise.resolve({ data: [], error: null }) }),
    }),
    runRelationalQueryWithTimeout: async (query) => {
      const { data, error } = await query;
      if (error) throw error;
      return data;
    },
    renderAdminPageHeader: ({ title, actions }) => `<header>${title}${actions}</header>`,
    renderAdminIconButton: ({ label }) => `<button>${label}</button>`,
    renderAdminPager: () => '',
    canAdminAccessPage: () => true,
    getCurrentAdminAccess: () => null,
  });
  vm.runInContext(
    [sliceFunction('escapeHtml'), sliceFunction('formatAdminCount'), sliceFunction('isUuidValue'), mainSource.slice(blockStart, blockEnd)].join('\n'),
    context,
  );
  return context;
}

const flush = () => new Promise((resolve) => {
  setImmediate(resolve);
});

test('Results is a People page in the admin menu', () => {
  assert.match(mainSource, /const ADMIN_DATA_PAGES = \[[^\]]*"results"/);
  assert.match(mainSource, /\{ page: "results", label: "Student results" \}/);
  assert.ok(mainSource.includes('\n  results: "people",\n'));
});

test('a query is asked once per key and an older reply is dropped', async () => {
  let release;
  const ctx = loadResults({ rpc: () => new Promise((resolve) => { release = resolve; }) });
  ctx.loadAdminResultsSlot('overview', 'a', 'admin_results_overview', () => ({}));
  ctx.loadAdminResultsSlot('overview', 'a', 'admin_results_overview', () => ({}));
  assert.equal(ctx.calls.length, 1);
  const firstRelease = release;
  ctx.loadAdminResultsSlot('overview', 'b', 'admin_results_overview', () => ({}));
  assert.equal(ctx.calls.length, 2);
  firstRelease({ data: { from: 'a' }, error: null });
  await flush();
  const slot = ctx.getAdminResultsSlot('overview');
  assert.equal(slot.data, null, 'reply for key a must not land on key b');
  assert.equal(slot.loading, true);
  release({ data: { from: 'b' }, error: null });
  await flush();
  assert.equal(slot.data.from, 'b');
  assert.equal(slot.done, true);
});

test('student list escapes names and shows zero counts', async () => {
  const ctx = loadResults({
    rpc: () => Promise.resolve({
      data: [{
        user_id: '11111111-1111-1111-1111-111111111111',
        full_name: '<img src=x onerror=alert(1)>',
        email: 'a"b@example.com',
        academic_year: 2,
        academic_semester: 1,
        tests: 0,
        answered: 0,
        correct: 0,
        unfinished_tests: 0,
        last_seen_at: null,
        total_count: 1,
      }],
      error: null,
    }),
  });
  const results = ctx.getAdminResultsState();
  results.tab = 'students';
  ctx.renderAdminResultsSection();
  await flush();
  const html = ctx.renderAdminResultsSection();
  assert.ok(!html.includes('<img src=x'), 'name must be escaped');
  assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'));
  assert.ok(html.includes('a&quot;b@example.com'));
  assert.match(html, /<td class="is-number">0<\/td>/, 'zero counts must render as 0, not empty');
  assert.ok(html.includes('Never'));
});

test('student view escapes mistakes and strips markup from stems', async () => {
  const ctx = loadResults({
    rpc: () => Promise.resolve({
      data: {
        profile: { full_name: 'Sara', email: 's@example.com', approved: true },
        totals: { tests: 1, answered: 2, correct: 1 },
        activity: {},
        courses: [{ course_id: 'c1', course_name: 'Gyn <b>', tests: 1, answered: 2, correct: 1, questions_answered: 2, published_questions: 10 }],
        topics: [{ course_id: 'c1', topic_id: 't1', topic_name: 'Topic & co', answered: 2, correct: 1 }],
        tests: [],
        unfinished: [],
        mistakes: [{ course_id: 'c1', topic_id: 't1', topic_name: 'Topic & co', stem: '<p>Which <script>x</script>?</p>', selected: ['B'], correct: ['A'] }],
      },
      error: null,
    }),
  });
  const results = ctx.getAdminResultsState();
  results.studentId = 'u1';
  ctx.renderAdminResultsSection();
  await flush();
  let html = ctx.renderAdminResultsSection();
  assert.ok(html.includes('Gyn &lt;b&gt;'));
  assert.ok(html.includes('2 of 10 (20%)'));
  results.studentTab = 'mistakes';
  html = ctx.renderAdminResultsSection();
  assert.ok(!html.includes('<script>'));
  assert.ok(html.includes('Picked B'));
  assert.ok(html.includes('Answer A'));
  assert.ok(html.includes('Topic &amp; co'));
});

test('Users page shows the last test and opens the Tests tab', async () => {
  const id = '2a6f3c1e-8b4d-4c2a-9f1e-3d5b7a9c1e2f';
  const ctx = loadResults({
    rpc: (name, params) => {
      if (name !== 'admin_results_last_tests') {
        return Promise.resolve({ data: null, error: null });
      }
      assert.deepEqual([...params.p_user_ids], [id]);
      return Promise.resolve({ data: [{ user_id: id, tests: 3, last_test_at: new Date().toISOString(), last_answered: 40, last_correct: 30 }], error: null });
    },
  });
  const student = { id: 'local-1', supabaseAuthId: id, role: 'student', name: 'Omar <b>' };
  const admin = { id: '7c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f', role: 'admin' };
  ctx.ensureAdminResultsLastTests([student, admin]);
  ctx.ensureAdminResultsLastTests([student]);
  assert.equal(ctx.calls.length, 1, 'one call for the page, admins skipped, no repeat while pending');
  assert.ok(ctx.renderAdminUserLastTestCell(student).includes('…'));
  await flush();
  const html = ctx.renderAdminUserLastTestCell(student);
  assert.ok(html.includes('75%'));
  assert.ok(html.includes('30/40'));
  assert.ok(html.includes('3 tests'));
  assert.ok(html.includes(`data-action="admin-user-tests" data-profile-id="${id}"`));
  assert.ok(html.includes('Tests of Omar &lt;b&gt;'));
  assert.ok(ctx.renderAdminUserLastTestCell(admin).includes('—'));

  ctx.openAdminResultsStudent(id, { tab: 'tests', returnTo: 'users' });
  const results = ctx.getAdminResultsState();
  assert.equal(results.studentTab, 'tests');
  assert.equal(ctx.state.adminPage, 'results');
  assert.ok(ctx.renderAdminResultsSection().includes('Back to Users'));
});

test('a student with no finished tests says so', async () => {
  const id = '5e4d3c2b-1a09-4f8e-a7d6-c5b4a3928170';
  const ctx = loadResults({ rpc: () => Promise.resolve({ data: [], error: null }) });
  const student = { id, role: 'student' };
  ctx.ensureAdminResultsLastTests([student]);
  await flush();
  assert.ok(ctx.renderAdminUserLastTestCell(student).includes('No tests yet'));
});
