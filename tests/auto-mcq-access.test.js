const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const utils = require('../universities-utils.js');

const MIGRATION = 'supabase/migrations/20260928125817_student_auto_mcq_access.sql';

test('flag key and description match the migration that seeds the row', () => {
  const sql = fs.readFileSync(MIGRATION, 'utf8');
  const seed = sql.slice(sql.indexOf('insert into public.app_feature_flags'));
  assert.match(seed, new RegExp(`'${utils.AUTO_MCQ_ACCESS_FEATURE_KEY}'`));
  assert.ok(seed.includes(`'${utils.AUTO_MCQ_ACCESS_FEATURE_DESCRIPTION}'`));
  assert.equal(utils.getFeatureFlagLabel('student_auto_mcq_access'), 'Auto MCQ access for new students');
  assert.equal(utils.getFeatureFlagLabel(' unknown_flag '), 'unknown_flag');
});

test('a hold is a student with a real stamp and MCQ access still off', () => {
  const heldAt = '2026-09-28T10:00:00.000Z';
  assert.equal(utils.normalizeMcqAccessHeldAt('2026-09-28T10:00:00+00:00'), heldAt);
  assert.equal(utils.normalizeMcqAccessHeldAt(''), null);
  assert.equal(utils.normalizeMcqAccessHeldAt('not a date'), null);
  assert.equal(utils.normalizeMcqAccessHeldAt(null), null);
  assert.equal(utils.isMcqAccessHeld({ role: 'student', mcqAccessEnabled: false, mcqAccessHeldAt: heldAt }), true);
  // Just activated, before the re-read lands: no badge.
  assert.equal(utils.isMcqAccessHeld({ role: 'student', mcqAccessEnabled: true, mcqAccessHeldAt: heldAt }), false);
  assert.equal(utils.isMcqAccessHeld({ role: 'student', mcqAccessEnabled: false, mcqAccessHeldAt: null }), false);
  assert.equal(utils.isMcqAccessHeld({ role: 'creator', mcqAccessEnabled: false, mcqAccessHeldAt: heldAt }), false);
  assert.match(utils.formatMcqHeldSince(heldAt), /2026/);
  assert.equal(utils.formatMcqHeldSince(null), '');
});

test('state line and confirmations say what will happen', () => {
  assert.match(utils.describeAutoMcqAccessState(true, 0), /^On: new Medicine students/);
  assert.match(utils.describeAutoMcqAccessState(false, 3), /^Off: .*Video Courses only.*3 students waiting now\./);
  assert.match(utils.describeAutoMcqAccessState(false, 1), /1 student waiting now\./);
  assert.match(utils.describeAutoMcqAccessState(false, 0), /Nobody is waiting now\./);
  assert.doesNotMatch(utils.describeAutoMcqAccessState(false, null), /waiting now|Nobody/);
  assert.match(utils.describeAutoMcqAccessState(null), /Checking/);

  assert.ok(utils.buildAutoMcqAccessConfirmMessage(false).includes(
    'New students will get Video Courses only until you activate MCQ access for each of them, or turn this back on.',
  ));
  assert.match(utils.buildAutoMcqAccessConfirmMessage(true, 4), /4 students waiting for MCQ activation will all be activated now\./);
  assert.match(utils.buildAutoMcqAccessConfirmMessage(true, 0), /No students are waiting/);
  assert.match(utils.buildAutoMcqAccessConfirmMessage(true, null), /could not be read/);
});

// ---------------------------------------------------------------------------
// The real main.js functions, in an isolated context, against a fake server
// that behaves like the migration's triggers.
// ---------------------------------------------------------------------------
const mainSource = fs.readFileSync('main.js', 'utf8');
const slice = (from, to) => {
  const start = mainSource.indexOf(from);
  const end = mainSource.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `main.js markers moved: ${from}`);
  return mainSource.slice(start, end);
};
const topLevelFunction = (name) => slice(`\nfunction ${name}(`, '\n}\n') + '\n}\n';
const autoMcqSource = slice('// Auto MCQ access for new students. Migration', '// University administration.');
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);

const ADMIN_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function fakeServer({ enabled = true, profiles = [], hasRow = true, flagReadError = null } = {}) {
  const db = { enabled, hasRow, profiles: profiles.map((row) => ({ ...row })), log: [] };
  db.client = {
    from(table) {
      const call = { table, ops: [] };
      db.log.push(call);
      const builder = {
        select(columns, options) { call.ops.push(['select', columns, options]); return builder; },
        upsert(payload, options) { call.ops.push(['upsert', payload, options]); return builder; },
        eq(column, value) { call.ops.push(['eq', column, value]); return builder; },
        not(column, op, value) { call.ops.push(['not', column, op, value]); return builder; },
        maybeSingle() { call.ops.push(['maybeSingle']); return builder; },
        then(resolve, reject) {
          return Promise.resolve(respond(call)).then(resolve, reject);
        },
      };
      return builder;
    },
  };
  function respond(call) {
    const upsert = call.ops.find(([op]) => op === 'upsert');
    if (call.table === 'app_feature_flags' && upsert) {
      const next = upsert[1].enabled === true;
      // trg_feature_flags_release_mcq: false -> true activates every held student.
      if (next && db.enabled !== true && db.hasRow) {
        db.profiles.forEach((row) => {
          if (row.role === 'student' && row.mcq_access_held_at) {
            row.mcq_access_enabled = true;
            row.mcq_access_held_at = null;
          }
        });
      }
      db.enabled = next;
      db.hasRow = true;
      return { data: null, error: null };
    }
    if (call.table === 'app_feature_flags') {
      if (flagReadError) return { data: null, error: flagReadError };
      return { data: db.hasRow ? { feature_key: 'student_auto_mcq_access', enabled: db.enabled } : null, error: null };
    }
    if (call.table === 'profiles' && call.ops.some(([op, , options]) => op === 'select' && options?.head)) {
      const count = db.profiles.filter((row) => row.role === 'student' && row.mcq_access_held_at).length;
      return { data: null, count, error: null };
    }
    if (call.table === 'profiles') {
      const id = call.ops.find(([op, column]) => op === 'eq' && column === 'id')?.[2];
      const row = db.profiles.find((entry) => entry.id === id);
      return { data: row ? { id: row.id, mcq_access_enabled: row.mcq_access_enabled, mcq_access_held_at: row.mcq_access_held_at } : null, error: null };
    }
    return { data: null, error: null };
  }
  return db;
}

function harness({ server = fakeServer(), confirm = () => true, users = [] } = {}) {
  const toasts = [];
  const prompts = [];
  let cachedUsers = users;
  const state = { route: 'admin', adminPage: 'users', mcqAccessHeldCount: null, studentAutoMcqAccessEnabled: null, studentAutoMcqAccessLoadedAt: 0 };
  const context = vm.createContext({
    state, MedBankUniversities: utils, console: { warn() {} }, Date, Number, Promise, Object, Array, String,
    escapeHtml,
    toast: (message) => toasts.push(message),
    render: () => { context.renders = (context.renders || 0) + 1; },
    getRelationalClient: () => server.client,
    getCurrentUser: () => ({ id: ADMIN_ID, role: 'admin' }),
    getUserProfileId: (user) => user?.supabaseAuthId || user?.id || '',
    isUuidValue: (value) => /^[0-9a-f-]{36}$/i.test(String(value || '')),
    getErrorMessage: (error, fallback) => error?.message || fallback,
    runRelationalQueryWithTimeout: async (query) => { const result = await query; if (result.error) throw result.error; return result.data; },
    runWithTimeoutResult: (query) => Promise.resolve(query),
    SUPABASE_QUERY_TIMEOUT_MS: 1000,
    hydrateRelationalProfiles: async () => { context.hydrated = (context.hydrated || 0) + 1; },
    shouldDeferAdminUsersAutoRender: () => false,
    renderAdminAccessSwitchContent: (label, on) => `${escapeHtml(label)} ${on ? 'On' : 'Off'}`,
    getUsers: () => cachedUsers.map((entry) => ({ ...entry })),
    saveLocalOnly: (_key, next) => { cachedUsers = next; },
    STORAGE_KEYS: { users: 'users' },
    normalizeUniversityIdValue: (value) => value || null,
    normalizeCollegeValue: (value) => value || null,
    window: { confirm: (message) => { prompts.push(message); return confirm(message); } },
  });
  vm.runInContext(
    autoMcqSource
      + topLevelFunction('getUniversitiesUtils')
      + topLevelFunction('readProfileUniversityFields')
      + topLevelFunction('readProfileMcqHoldFields')
      + topLevelFunction('isUserMcqAccessHeld')
      + topLevelFunction('applyServerUniversityFieldsToLocalUser'),
    context,
  );
  context.toasts = toasts;
  context.prompts = prompts;
  context.cachedUsers = () => cachedUsers;
  return context;
}

const HELD = (id, heldAt = '2026-09-28T09:00:00Z') => ({ id, role: 'student', mcq_access_enabled: false, mcq_access_held_at: heldAt });

test('profile rows keep "read and empty" apart from "not read" for the hold', () => {
  const h = harness();
  assert.deepEqual({ ...h.readProfileMcqHoldFields({ mcq_access_held_at: null }) }, { mcqAccessHeldAt: null });
  assert.deepEqual({ ...h.readProfileMcqHoldFields({ mcq_access_held_at: '2026-09-28T09:00:00+00:00' }) }, { mcqAccessHeldAt: '2026-09-28T09:00:00.000Z' });
  assert.deepEqual({ ...h.readProfileMcqHoldFields({ id: 'x' }) }, {});
});

test('every admin-list profile select reads mcq_access_held_at', () => {
  const selects = [...mainSource.matchAll(/\.select\("id,public_user_id,[^"]*"\)/g)].map((match) => match[0]);
  assert.ok(selects.length >= 5);
  for (const select of selects) {
    assert.match(select, /mcq_access_held_at/);
  }
});

test('flag reads: a missing row is off, and a failed read keeps the last value', async () => {
  const missing = harness({ server: fakeServer({ hasRow: false }) });
  assert.equal(await missing.loadStudentAutoMcqAccessFlag(), true);
  assert.equal(missing.state.studentAutoMcqAccessEnabled, false);

  const failing = harness({ server: fakeServer({ flagReadError: { message: 'network down' } }) });
  failing.state.studentAutoMcqAccessEnabled = true;
  assert.equal(await failing.loadStudentAutoMcqAccessFlag({ force: true }), false);
  assert.equal(failing.state.studentAutoMcqAccessEnabled, true);
  assert.equal(failing.state.studentAutoMcqAccessError, 'network down');
});

test('the waiting count is an exact head count of held students', async () => {
  const server = fakeServer({ profiles: [HELD('s1'), HELD('s2'), { id: 's3', role: 'student', mcq_access_enabled: true, mcq_access_held_at: null }] });
  const h = harness({ server });
  assert.equal(await h.loadMcqAccessHeldCount(), 2);
  const call = server.log.at(-1);
  assert.equal(call.table, 'profiles');
  assert.deepEqual(JSON.parse(JSON.stringify(call.ops)), [
    ['select', 'id', { count: 'exact', head: true }],
    ['not', 'mcq_access_held_at', 'is', null],
    ['eq', 'role', 'student'],
  ]);
});

test('turning it on confirms with the waiting count, writes, then re-reads everything', async () => {
  const server = fakeServer({ enabled: false, profiles: [HELD('s1'), HELD('s2'), HELD('s3')] });
  const h = harness({ server });
  await h.loadStudentAutoMcqAccessFlag();
  assert.equal(await h.toggleStudentAutoMcqAccess(), true);
  assert.match(h.prompts[0], /3 students waiting for MCQ activation will all be activated now/);
  const upsert = server.log.find((call) => call.ops.some(([op]) => op === 'upsert'));
  assert.deepEqual(JSON.parse(JSON.stringify(upsert.ops[0][1])), {
    feature_key: 'student_auto_mcq_access',
    enabled: true,
    updated_by: ADMIN_ID,
    description: utils.AUTO_MCQ_ACCESS_FEATURE_DESCRIPTION,
  });
  // After the write: the flag, the profiles and the count all come from the server.
  const afterWrite = server.log.slice(server.log.indexOf(upsert) + 1).map((call) => call.table);
  assert.ok(afterWrite.includes('app_feature_flags'));
  assert.ok(afterWrite.includes('profiles'));
  assert.equal(h.hydrated, 1);
  assert.equal(h.state.studentAutoMcqAccessEnabled, true);
  assert.equal(h.state.mcqAccessHeldCount, 0);
  assert.equal(h.state.studentAutoMcqAccessSaving, false);
  assert.match(h.toasts.at(-1), /Auto MCQ access is on/);
});

test('turning it off confirms with the exact warning; cancelling writes nothing', async () => {
  const server = fakeServer({ enabled: true });
  const h = harness({ server, confirm: () => false });
  await h.loadStudentAutoMcqAccessFlag();
  assert.equal(await h.toggleStudentAutoMcqAccess(), false);
  assert.ok(h.prompts[0].includes('New students will get Video Courses only until you activate MCQ access for each of them, or turn this back on.'));
  assert.equal(server.log.some((call) => call.ops.some(([op]) => op === 'upsert')), false);
  assert.equal(server.enabled, true);
});

test('the state shown after a write is what the server says, not what was sent', async () => {
  // A write that "succeeds" but does not change the row (e.g. filtered by RLS).
  const server = fakeServer({ enabled: false });
  const original = server.client.from.bind(server.client);
  server.client.from = (table) => {
    const builder = original(table);
    const upsert = builder.upsert;
    builder.upsert = (payload, options) => { upsert(payload, options); builder.then = (resolve) => resolve({ data: null, error: null }); return builder; };
    return builder;
  };
  const h = harness({ server });
  await h.loadStudentAutoMcqAccessFlag();
  await h.toggleStudentAutoMcqAccess();
  assert.equal(h.state.studentAutoMcqAccessEnabled, false);
});

test('a refused write shows the error and the switch is not stuck busy', async () => {
  const server = fakeServer({ enabled: true });
  const original = server.client.from.bind(server.client);
  server.client.from = (table) => {
    const builder = original(table);
    builder.upsert = () => { builder.then = (resolve) => resolve({ data: null, error: { message: 'new row violates row-level security policy' } }); return builder; };
    return builder;
  };
  const h = harness({ server });
  await h.loadStudentAutoMcqAccessFlag();
  assert.equal(await h.toggleStudentAutoMcqAccess(), false);
  assert.equal(h.state.studentAutoMcqAccessSaving, false);
  assert.equal(h.state.studentAutoMcqAccessEnabled, true);
  assert.match(h.state.studentAutoMcqAccessError, /row-level security/);
});

test('panel and row marker render the label, state, waiting badge and Activate action', () => {
  const heldUser = { id: 's1', role: 'student', mcqAccessEnabled: false, mcqAccessHeldAt: '2026-09-27T12:00:00.000Z' };
  const h = harness({ users: [heldUser] });
  h.state.studentAutoMcqAccessEnabled = false;
  h.state.studentAutoMcqAccessLoadedAt = 1;
  h.state.mcqAccessHeldCount = 1;
  const panel = h.renderAdminAutoMcqAccessPanel([heldUser]);
  assert.match(panel, /Auto MCQ access for new students Off/);
  assert.match(panel, /aria-checked="false"/);
  assert.match(panel, /1 student waiting now/);
  assert.match(panel, /Show waiting for MCQ \(1\)/);
  assert.doesNotMatch(panel, /disabled/);

  const marker = h.renderAdminUserMcqHold(heldUser);
  assert.match(marker, /Waiting for MCQ/);
  assert.match(marker, /waiting since 27 Sept? 2026/);
  assert.match(marker, /data-action="activate-user-mcq"/);
  assert.doesNotMatch(marker, /hidden/);
  assert.match(h.renderAdminUserMcqHold({ ...heldUser, mcqAccessHeldAt: null }), /hidden><\/span>$/);
  assert.equal(h.renderAdminUserMcqHold({ id: 'a', role: 'admin' }), '');

  h.state.studentAutoMcqAccessEnabled = null;
  h.state.studentAutoMcqAccessLoadedAt = 0;
  h.state.studentAutoMcqAccessLoading = true;
  assert.match(h.renderAdminAutoMcqAccessPanel([]), /role="switch"[^>]*disabled/);
});

test('re-reading one student replaces the cached MCQ fields with the server row', async () => {
  const server = fakeServer({ profiles: [{ id: 's1', role: 'student', mcq_access_enabled: true, mcq_access_held_at: null }] });
  const h = harness({ server, users: [{ id: 's1', role: 'student', mcqAccessEnabled: false, mcqAccessHeldAt: '2026-09-27T12:00:00.000Z' }] });
  await h.rereadAdminUserMcqAccessFields('s1');
  const cached = h.cachedUsers()[0];
  assert.equal(cached.mcqAccessEnabled, true);
  assert.equal(cached.mcqAccessHeldAt, null);
  assert.equal(h.isUserMcqAccessHeld(cached), false);
});

test('the Users filter keeps only held students when asked', () => {
  const context = vm.createContext({
    MedBankUniversities: utils,
    normalizeAcademicYearOrNull: () => null,
    normalizeAcademicSemesterOrNull: () => null,
    splitBulkUserSearchTerms: () => [],
    matchesAdminUserApprovalFilter: () => true,
    matchesAdminUserProviderFilter: () => true,
    matchesAdminUserSearchTerm: () => true,
  });
  vm.runInContext(topLevelFunction('getUniversitiesUtils') + topLevelFunction('isUserMcqAccessHeld') + topLevelFunction('matchesAdminUserFilters'), context);
  const held = { role: 'student', mcqAccessEnabled: false, mcqAccessHeldAt: '2026-09-27T12:00:00.000Z' };
  const active = { role: 'student', mcqAccessEnabled: true, mcqAccessHeldAt: null };
  assert.equal(context.matchesAdminUserFilters(held, { mcqHeld: true }), true);
  assert.equal(context.matchesAdminUserFilters(active, { mcqHeld: true }), false);
  assert.equal(context.matchesAdminUserFilters(active, {}), true);
});
