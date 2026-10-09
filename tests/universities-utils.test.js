const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const utils = require('../universities-utils.js');

const O6U = { id: '11111111-1111-4111-8111-111111111111', name: 'October 6 University', name_ar: 'جامعة 6 أكتوبر', mcq_bank_available: true, is_active: true, sort_order: 0 };
const OTHER = { id: '22222222-2222-4222-8222-222222222222', name: 'Cairo University', name_ar: null, mcq_bank_available: false, is_active: true, sort_order: 10 };
const HIDDEN = { id: '33333333-3333-4333-8333-333333333333', name: 'Old University', mcq_bank_available: true, is_active: false, sort_order: 5 };
const list = utils.sortUniversities([OTHER, O6U, HIDDEN]);

test('college vocabulary matches the profiles_college_ck CHECK constraint exactly', () => {
  const migration = fs.readFileSync('supabase/migrations/20260928083023_universities_and_college_mcq_eligibility.sql', 'utf8');
  const check = migration.slice(migration.indexOf('profiles_college_ck check ('));
  const values = [...check.slice(0, check.indexOf(');')).matchAll(/'([a-z_]+)'/g)].map((match) => match[1]);
  assert.deepEqual([...utils.COLLEGE_VALUES], values);
  assert.equal(utils.normalizeCollege(' Medicine '), 'medicine');
  assert.equal(utils.normalizeCollege('law'), null);
  assert.equal(utils.normalizeCollege(''), null);
  assert.equal(utils.getCollegeLabel('physical_therapy'), 'Physical Therapy');
  assert.equal(utils.getCollegeLabel('nope'), '');
});

test('universities sort by sort_order then name, and bad rows are dropped', () => {
  assert.deepEqual(list.map((entry) => entry.name), ['October 6 University', 'Old University', 'Cairo University']);
  assert.equal(utils.sortUniversities([{ id: 'not-a-uuid', name: 'X' }, { id: O6U.id, name: '  ' }, null]).length, 0);
  assert.equal(utils.normalizeUniversityRow({ ...OTHER, sort_order: 'abc' }).sort_order, 100);
});

test('eligibility: only Medicine at a university that offers the bank', () => {
  const eligible = (universityId, college, role = 'student') => utils.resolveMcqEligibility({ role, universityId, college }, list);
  assert.equal(eligible(O6U.id, 'medicine'), true);
  assert.equal(eligible(O6U.id, 'dentistry'), false);
  assert.equal(eligible(OTHER.id, 'medicine'), false);
  // A hidden university still counts when it offers the bank (the DB ignores is_active here).
  assert.equal(eligible(HIDDEN.id, 'medicine'), true);
  // Known-missing values are ineligible, exactly as the trigger decides.
  assert.equal(eligible(null, 'medicine'), false);
  assert.equal(eligible(O6U.id, null), false);
  // A non-medicine college is decidable without the list.
  assert.equal(utils.resolveMcqEligibility({ role: 'student', universityId: O6U.id, college: 'pharmacy' }, null), false);
  // Not read yet, or a university this browser cannot see: unknown, never "ineligible".
  assert.equal(eligible(undefined, undefined), null);
  assert.equal(eligible('44444444-4444-4444-8444-444444444444', 'medicine'), null);
  assert.equal(utils.resolveMcqEligibility({ role: 'student', universityId: O6U.id, college: 'medicine' }, null), null);
  // Admins and creators are never restricted by this rule.
  assert.equal(eligible(null, null, 'admin'), true);
  assert.equal(eligible(OTHER.id, 'pharmacy', 'creator'), true);
});

test('university drafts are validated and trimmed into an allowlisted payload', () => {
  const ok = utils.validateUniversityDraft({ name: '  Ain  Shams University ', name_ar: ' ', sort_order: '7', is_active: true, mcq_bank_available: false, extra: 'x' });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.payload, { name: 'Ain Shams University', name_ar: null, sort_order: 7, is_active: true, mcq_bank_available: false });
  assert.equal(utils.validateUniversityDraft({ name: 'A' }).ok, false);
  assert.equal(utils.validateUniversityDraft({ name: 'Valid', sort_order: 1.5 }).ok, false);
  assert.equal(utils.validateUniversityDraft({ name: 'Valid', sort_order: '' }).payload.sort_order, 100);
});

test('database errors become friendly messages and never leak raw text', () => {
  assert.match(utils.describeUniversityError({ code: '23503', message: 'RAW fk violation' }), /hide it from sign-up instead/i);
  assert.match(utils.describeUniversityError({ code: '23505', message: 'RAW duplicate' }), /already exists/);
  assert.match(utils.describeUniversityError({ code: '23514', message: 'UNIVERSITY_NOT_AVAILABLE' }), /no longer available/);
  assert.match(utils.describeUniversityError({ code: '42501', message: 'permission denied for table universities' }), /permission/);
  const restricted = { message: 'Service for this project is restricted due to the following violations: exceed_egress_quota. The project owner must upgrade their plan or remove spend caps to restore service.' };
  assert.match(utils.describeUniversityError(restricted, 'fallback'), /temporarily unavailable/);
  assert.doesNotMatch(utils.describeUniversityError(restricted, 'fallback'), /egress|upgrade|plan/i);
  assert.match(utils.describeUniversityError({ status: 402, message: '' }, 'fallback'), /temporarily unavailable/);
  assert.equal(utils.isServiceRestrictedError({ code: 'TIMEOUT', message: 'Universities query timed out.' }), false);
  for (const error of [{ code: '23503', message: 'RAW' }, { code: 'XX', message: 'RAW' }, null]) {
    assert.doesNotMatch(utils.describeUniversityError(error), /RAW/);
  }
});

test('UMD browser namespace and static runtime registrations', () => {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync('universities-utils.js', 'utf8'), context);
  assert.equal(context.MedBankUniversities.normalizeCollege('medicine'), 'medicine');
  const bootstrap = fs.readFileSync('bootstrap.js', 'utf8');
  assert.ok(bootstrap.indexOf('loadScript(`universities-utils.js') > 0);
  assert.ok(bootstrap.indexOf('loadScript(`universities-utils.js') < bootstrap.indexOf('loadScript(`main.js'));
  assert.match(fs.readFileSync('sw.js', 'utf8'), /universities-utils\.js/);
  assert.match(JSON.parse(fs.readFileSync('package.json')).scripts.lint, /universities-utils\.js/);
});

// ---------------------------------------------------------------------------
// The real classic-script functions from main.js, in an isolated context.
// ---------------------------------------------------------------------------
const mainSource = fs.readFileSync('main.js', 'utf8');
const slice = (from, to) => {
  const start = mainSource.indexOf(from);
  const end = mainSource.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `main.js markers moved: ${from}`);
  return mainSource.slice(start, end);
};
const topLevelFunction = (name) => slice(`\nfunction ${name}(`, '\n}\n') + '\n}\n';
const coreSource = slice('// University + college (MCQ Bank eligibility).', 'function getAuthProviderFromAuthUser(');
const adminSource = slice('// University administration.', '// Mobile pop-up administration.');
const escapeHtml = (value) => String(value || '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);

function harness(overrides = {}) {
  const toasts = [];
  const state = { route: 'admin', adminPage: 'universities', universities: [], universitiesLoadedAt: 1, universitiesLoading: false, universitiesError: '', adminUniversityDraft: null, adminUniversitySaving: false };
  let users = overrides.users || [];
  const context = vm.createContext({
    state, MedBankUniversities: utils, console, Date, toasts,
    escapeHtml, toast: (message) => toasts.push(message), render: () => {},
    getUsers: () => users, saveLocalOnly: (_key, next) => { users = next; }, STORAGE_KEYS: { users: 'users' },
    getUserProfileId: (user) => user?.supabaseAuthId || user?.id || '',
    isUuidValue: (value) => /^[0-9a-f-]{36}$/i.test(String(value || '')),
    getCurrentUser: () => ({ id: 'admin', role: 'admin' }),
    getRelationalClient: () => overrides.client || null,
    runRelationalQueryWithTimeout: async (query) => { const result = await query; if (result.error) throw result.error; return result.data; },
    hydrateRelationalProfiles: async () => { context.hydrated = (context.hydrated || 0) + 1; },
    getErrorMessage: (error, fallback) => error?.message || fallback,
    isStudentProfileDataComplete: () => true,
    isVideoCoursesHidden: () => false,
    window: { confirm: overrides.confirm || (() => true) },
    ...overrides.globals,
  });
  vm.runInContext(coreSource + adminSource
    + topLevelFunction('isUserAccessApproved') + topLevelFunction('isUserMcqAccessEnabled')
    + topLevelFunction('getMcqAccessBlockedMessage') + topLevelFunction('buildStudentEnrollmentAuthMetadata'), context);
  context.getUsersNow = () => users;
  return context;
}

test('profile rows keep "read and empty" (null) apart from "not read" (undefined)', () => {
  const h = harness();
  assert.deepEqual({ ...h.readProfileUniversityFields({ university_id: null, college: null }) }, { universityId: null, college: null });
  assert.deepEqual({ ...h.readProfileUniversityFields({ university_id: O6U.id.toUpperCase(), college: 'MEDICINE' }) }, { universityId: O6U.id, college: 'medicine' });
  assert.deepEqual({ ...h.readProfileUniversityFields({ id: 'x' }) }, {});
  assert.equal(h.isStudentUniversityCollegeMissing({ role: 'student', universityId: null, college: 'medicine' }), true);
  assert.equal(h.isStudentUniversityCollegeMissing({ role: 'student' }), false);
  assert.equal(h.isStudentUniversityCollegeMissing({ role: 'admin', universityId: null, college: null }), false);
});

test('MCQ access is hidden for ineligible students even when a stale flag says on', () => {
  const h = harness({
    globals: {
      getCurrentUser: () => null,
    },
  });
  h.state.universities = list;
  const student = (fields) => ({ role: 'student', isApproved: true, mcqAccessEnabled: true, ...fields });
  assert.equal(h.isUserMcqAccessEnabled(student({ universityId: O6U.id, college: 'medicine' })), true);
  assert.equal(h.isUserMcqAccessEnabled(student({ universityId: O6U.id, college: 'nursing' })), false);
  assert.equal(h.isUserMcqAccessEnabled(student({ universityId: OTHER.id, college: 'medicine' })), false);
  // Unknown eligibility defers to the server flag.
  assert.equal(h.isUserMcqAccessEnabled(student({})), true);
  assert.equal(h.isUserMcqAccessEnabled(student({ mcqAccessEnabled: false })), false);
  assert.equal(h.isUserMcqAccessEnabled({ role: 'admin' }), true);
  assert.match(h.getMcqAccessBlockedMessage(student({ universityId: OTHER.id, college: 'medicine' })), /Medicine students at October 6 University/);
  assert.match(h.getMcqAccessBlockedMessage(student({ universityId: O6U.id, college: 'medicine' })), /disabled for this account/);
});

test('sign-up metadata carries university_id and college for the auth trigger', () => {
  const h = harness({ globals: {
    normalizeAcademicYearOrNull: (value) => Number(value) || null,
    normalizeAcademicSemesterOrNull: (value) => Number(value) || null,
    sanitizeCourseAssignments: (value) => value,
    normalizeAuthProvider: (value) => value,
  } });
  const metadata = h.buildStudentEnrollmentAuthMetadata({ name: 'A', universityId: O6U.id, college: 'medicine', academicYear: 1, academicSemester: 1, assignedCourses: [] });
  assert.equal(metadata.university_id, O6U.id);
  assert.equal(metadata.college, 'medicine');
  const bare = h.buildStudentEnrollmentAuthMetadata({ name: 'A', universityId: 'nope', college: 'law' });
  assert.equal('university_id' in bare, false);
  assert.equal('college' in bare, false);
});

test('onboarding fields list only active universities, escape names, and carry the eligibility note', () => {
  const h = harness();
  h.state.universities = utils.sortUniversities([...list, { id: '55555555-5555-4555-8555-555555555555', name: '<b>Evil</b>', is_active: true, sort_order: 50 }]);
  const html = h.renderUniversityCollegeFields({ idPrefix: 'signup', universityId: O6U.id, college: 'medicine' });
  assert.match(html, new RegExp(`value="${O6U.id}" selected>October 6 University`));
  assert.doesNotMatch(html, /Old University/);
  assert.match(html, /&lt;b&gt;Evil&lt;\/b&gt;/);
  assert.match(html, /value="medicine" selected>Medicine/);
  assert.match(html, /data-mcq-eligibility-note role="status" hidden>The MCQ Bank is available for Medicine students/);
  assert.equal(h.isUniversityCollegeSelectionIneligible({ universityId: OTHER.id, college: 'medicine' }), true);
  assert.equal(h.isUniversityCollegeSelectionIneligible({ universityId: O6U.id, college: null }), false);
});

function fakeClient(log, responses = {}) {
  return {
    from(table) {
      const call = { table, ops: [] };
      log.push(call);
      const builder = {
        select(columns) { call.ops.push(['select', columns]); return builder; },
        update(payload) { call.ops.push(['update', payload]); return builder; },
        insert(payload) { call.ops.push(['insert', payload]); return builder; },
        delete() { call.ops.push(['delete']); return builder; },
        eq(column, value) { call.ops.push(['eq', column, value]); return builder; },
        order() { return builder; },
        then(resolve, reject) {
          const kind = call.ops.find(([op]) => ['update', 'insert', 'delete'].includes(op))?.[0] || 'read';
          const response = responses[kind] || (kind === 'read' ? { data: [O6U, OTHER] } : { data: [{ id: O6U.id }] });
          return Promise.resolve(response).then(resolve, reject);
        },
      };
      return builder;
    },
  };
}

test('admin list renders escaped rows, student counts and both switches', () => {
  const h = harness({ users: [{ role: 'student', universityId: O6U.id }, { role: 'student', universityId: O6U.id }, { role: 'admin', universityId: O6U.id }] });
  h.state.universities = utils.sortUniversities([O6U, { ...OTHER, name: '<script>x</script>' }]);
  const html = h.renderAdminUniversitiesSection();
  assert.match(html, /&lt;script&gt;x&lt;\/script&gt;/);
  assert.doesNotMatch(html, /<script>x/);
  assert.match(html, /dir="rtl" lang="ar">جامعة 6 أكتوبر/);
  assert.match(html, /<td>2<\/td>/);
  assert.match(html, /Turn off MCQ Bank/);
  assert.match(html, /Offer MCQ Bank/);
  assert.match(html, /<td>0<\/td>/);
});

test('delete of a university with students shows the friendly FK message and re-reads', async () => {
  const log = [];
  const h = harness({ client: fakeClient(log, { delete: { data: null, error: { code: '23503', message: 'update or delete on table "universities" violates foreign key constraint' } } }) });
  const ok = await h.runAdminUniversityMutation(async (client) => {
    await h.runRelationalQueryWithTimeout(client.from('universities').delete().eq('id', O6U.id).select('id'));
  });
  assert.equal(ok, false);
  assert.match(h.toasts.at(-1), /still has students.*Hide it from sign-up instead/);
  assert.doesNotMatch(h.toasts.join(' '), /foreign key/);
  // The list is always re-read from the server after a write attempt.
  assert.equal(log.at(-1).ops.some(([op]) => op === 'select'), true);
  assert.equal(log.at(-1).ops.some(([op]) => ['update', 'insert', 'delete'].includes(op)), false);
  assert.equal(h.state.adminUniversitySaving, false);
  assert.equal(h.hydrated, undefined);
});

test('an MCQ availability change re-reads the list and every profile', async () => {
  const log = [];
  const h = harness({ client: fakeClient(log) });
  const ok = await h.runAdminUniversityMutation(async (client) => {
    await h.runRelationalQueryWithTimeout(client.from('universities').update({ mcq_bank_available: false }).eq('id', O6U.id).select('id'));
  }, { refreshProfiles: true });
  assert.equal(ok, true);
  assert.equal(h.hydrated, 1);
  assert.deepEqual(h.state.universities.map((entry) => entry.name), ['October 6 University', 'Cairo University']);
});

test('the MCQ confirmation explains who is affected', () => {
  const prompts = [];
  const h = harness({ confirm: (message) => { prompts.push(message); return false; } });
  assert.equal(h.confirmUniversityMcqChange(O6U, false), false);
  assert.equal(h.confirmUniversityMcqChange(OTHER, true), false);
  assert.match(prompts[0], /Every student at October 6 University loses MCQ Bank access.*keep Video Courses/s);
  assert.match(prompts[1], /Every Medicine student at Cairo University gets MCQ Bank access/);
});

test('a student save keeps the server row, including the trigger-decided MCQ flag', async () => {
  const log = [];
  const client = fakeClient(log, { update: { data: [{ id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', university_id: OTHER.id, college: 'medicine', mcq_access_enabled: false }] } });
  const h = harness({ client, users: [{ id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', role: 'student', mcqAccessEnabled: true }] });
  const result = await h.saveOwnUniversityCollege({ id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, { universityId: OTHER.id, college: 'medicine' });
  assert.equal(result.ok, true);
  assert.deepEqual(JSON.parse(JSON.stringify(log[0].ops[0])), ['update', { university_id: OTHER.id, college: 'medicine' }]);
  const saved = h.getUsersNow()[0];
  assert.equal(saved.universityId, OTHER.id);
  assert.equal(saved.college, 'medicine');
  assert.equal(saved.mcqAccessEnabled, false);

  const refused = harness({ client: fakeClient([], { update: { data: null, error: { code: '23514', message: 'UNIVERSITY_NOT_AVAILABLE' } } }), users: [] });
  const failure = await refused.saveOwnUniversityCollege({ id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, { universityId: HIDDEN.id, college: 'medicine' });
  assert.equal(failure.ok, false);
  assert.match(failure.message, /no longer available/);
});
