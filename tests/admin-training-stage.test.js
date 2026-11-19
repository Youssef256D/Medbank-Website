'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const slice = (from, to) => {
  const start = mainSource.indexOf(from);
  const end = mainSource.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `main.js markers moved: ${from}`);
  return mainSource.slice(start, end);
};
const topLevelFunction = (name) => slice(`\nfunction ${name}(`, '\n}\n') + '\n}\n';
const asyncTopLevelFunction = (name) => slice(`\nasync function ${name}(`, '\n}\n') + '\n}\n';
const trainingStageSource = slice('// `profiles.training_stage`', '\nfunction isUserMcqAccessHeld(');
const enrollmentDraftSource = slice(
  '\nfunction normalizeAdminUserEnrollmentDraft(',
  '\nfunction getAdminUserEnrollmentSaveMode(',
);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
})[char]);

function harness({
  users = [],
  drafts = {},
  client = null,
  runWithTimeoutResultImpl = null,
  curriculumByTerm = {},
  allCourses = ['Medicine', 'Surgery', 'Pediatrics', 'Pathology', 'Pharmacology'],
} = {}) {
  let cachedUsers = users.map((entry) => ({ ...entry }));
  const state = {
    adminUserEnrollmentDrafts: { ...drafts },
    skipNextRouteAnimation: false,
  };
  const relationalSync = { lastUserLocalWriteAt: 0 };
  const toasts = [];
  const logs = [];
  const clearedOverrides = [];
  const savedLocalCalls = [];
  let mutationDepth = 0;
  let maxMutationDepth = 0;
  let renders = 0;
  const topicsMap = Object.fromEntries(allCourses.map((name) => [name, []]));

  const normalizeYear = (value) => {
    const n = Number(value);
    return Number.isInteger(n) && n >= 1 && n <= 7 ? n : null;
  };
  const normalizeSemester = (value) => {
    const n = Number(value);
    return Number.isInteger(n) && n >= 1 && n <= 3 ? n : null;
  };
  const sanitizeCourses = (courses) => [
    ...new Set((courses || []).map(String).filter((course) => Object.prototype.hasOwnProperty.call(topicsMap, course))),
  ];

  const context = vm.createContext({
    state,
    relationalSync,
    STORAGE_KEYS: { users: 'users' },
    SUPABASE_QUERY_TIMEOUT_MS: 1000,
    QBANK_COURSE_TOPICS: topicsMap,
    Date,
    Number,
    Object,
    Array,
    String,
    Set,
    Promise,
    escapeHtml,
    getUsers: () => cachedUsers.map((entry) => ({ ...entry })),
    saveLocalOnly: (_key, next) => {
      savedLocalCalls.push(next.map((entry) => ({ ...entry })));
      cachedUsers = next.map((entry) => ({ ...entry }));
    },
    getUserProfileId: (user) => user?.supabaseAuthId || user?.id || '',
    isUuidValue: (value) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || '').trim()),
    getRelationalClient: () => client,
    runWithTimeoutResult: runWithTimeoutResultImpl || (async (promise) => {
      try {
        return await promise;
      } catch (error) {
        return { data: null, error };
      }
    }),
    beginAdminUserMutation: () => {
      mutationDepth += 1;
      maxMutationDepth = Math.max(maxMutationDepth, mutationDepth);
    },
    endAdminUserMutation: () => {
      mutationDepth = Math.max(0, mutationDepth - 1);
    },
    normalizeAcademicYearOrNull: normalizeYear,
    normalizeAcademicSemesterOrNull: normalizeSemester,
    sanitizeCourseAssignments: sanitizeCourses,
    getCurriculumCourses: (year, semester) => sanitizeCourses(curriculumByTerm[`${year}-${semester}`] || []),
    maxIsoTimestamp: (a, b) => (Date.parse(String(a || '')) >= Date.parse(String(b || '')) ? (a || b || null) : b),
    clearPendingEnrollmentScopeOverride: (user) => {
      clearedOverrides.push(user?.id || '');
      return true;
    },
    appendSystemLog: (kind, message, meta) => logs.push({ kind, message, meta }),
    toast: (message) => toasts.push(message),
    render: () => { renders += 1; },
  });

  vm.runInContext(
    trainingStageSource
      + enrollmentDraftSource
      + topLevelFunction('getAdminUserEnrollmentViewModel')
      + topLevelFunction('renderAdminUserTrainingStageField')
      + asyncTopLevelFunction('saveAdminUserTrainingStage')
      + '\nthis.TRAINING_STAGES = TRAINING_STAGES;\n',
    context,
  );

  return {
    context,
    state,
    relationalSync,
    toasts,
    logs,
    clearedOverrides,
    savedLocalCalls,
    getUsersNow: () => cachedUsers,
    getRenders: () => renders,
    getMutationDepth: () => mutationDepth,
    getMaxMutationDepth: () => maxMutationDepth,
  };
}

function makeFakeClient(handler) {
  const calls = [];
  return {
    calls,
    from(table) {
      const call = { table, ops: [] };
      const builder = {
        update(payload) { call.ops.push(['update', payload]); return builder; },
        select(cols) { call.ops.push(['select', cols]); return builder; },
        eq(col, value) { call.ops.push(['eq', col, value]); return builder; },
        maybeSingle() { call.ops.push(['maybeSingle']); return builder; },
        then(resolve, reject) {
          calls.push(call);
          return Promise.resolve(handler(call)).then(resolve, reject);
        },
      };
      return builder;
    },
  };
}

test('TRAINING_STAGES, normalizeTrainingStage, getTrainingStageLabel, and readProfileTrainingStageFields match schema', () => {
  const { context } = harness();
  assert.deepEqual(
    [...context.TRAINING_STAGES].map((entry) => entry.value),
    ['intern_1', 'intern_2', 'junior_resident', 'senior_resident'],
  );
  assert.equal(context.normalizeTrainingStage(' INTERN_1 '), 'intern_1');
  assert.equal(context.normalizeTrainingStage('junior_resident'), 'junior_resident');
  assert.equal(context.normalizeTrainingStage('consultant'), null);
  assert.equal(context.normalizeTrainingStage(''), null);
  assert.equal(context.normalizeTrainingStage(null), null);
  assert.equal(context.getTrainingStageLabel('intern_2'), 'Intern year 2 (Imtiyaz)');
  assert.equal(context.getTrainingStageLabel('unknown'), '');
  assert.deepEqual({ ...context.readProfileTrainingStageFields({ training_stage: null }) }, { trainingStage: null });
  assert.deepEqual({ ...context.readProfileTrainingStageFields({ training_stage: 'SENIOR_RESIDENT' }) }, { trainingStage: 'senior_resident' });
  assert.deepEqual({ ...context.readProfileTrainingStageFields({ id: 'x' }) }, {});
});

test('every full profile select and university-change select reads training_stage', () => {
  const fullSelects = [...mainSource.matchAll(/\.select\("id,public_user_id,[^"]*"\)/g)].map((match) => match[0]);
  assert.ok(fullSelects.length >= 5);
  for (const select of fullSelects) {
    assert.match(select, /training_stage/);
  }
  const ownUniversityFn = slice('\nasync function saveOwnUniversityCollege(', '\n}\n');
  assert.match(ownUniversityFn, /\.select\("[^"]*training_stage[^"]*"\)/);
  const adminUniversityFn = slice('\nasync function loadAdminUserUniversityIntoDialog(', '\n}\n');
  assert.match(adminUniversityFn, /\.select\("[^"]*training_stage[^"]*"\)/);
});

test('renderAdminUserTrainingStageField shows only for medicine students and respects edit permission', () => {
  const { context } = harness();
  const html = context.renderAdminUserTrainingStageField({
    isStudent: true,
    college: ' Medicine ',
    trainingStage: 'intern_2',
    canEdit: true,
  });
  assert.match(html, /id="admin-user-edit-stage"/);
  assert.match(html, /data-action="set-user-training-stage"/);
  assert.doesNotMatch(html, /data-field=/);
  assert.doesNotMatch(html, /\sdisabled(?:\s|>)/);
  assert.match(html, /<option value="" >Studying \(year and semester\)<\/option>/);
  assert.match(html, /<option value="intern_2" selected>Intern year 2 \(Imtiyaz\)<\/option>/);
  assert.match(html, /Interns and residents get ER Shift in the app\./);

  const studyingHtml = context.renderAdminUserTrainingStageField({
    isStudent: true,
    college: 'medicine',
    trainingStage: null,
    canEdit: false,
  });
  assert.match(studyingHtml, /disabled/);
  assert.match(studyingHtml, /<option value="" selected>Studying \(year and semester\)<\/option>/);

  for (const args of [
    { isStudent: true, college: 'dentistry', trainingStage: null, canEdit: true },
    { isStudent: true, college: 'pharmacy', trainingStage: null, canEdit: true },
    { isStudent: true, college: null, trainingStage: null, canEdit: true },
    { isStudent: true, college: '', trainingStage: null, canEdit: true },
    { isStudent: false, college: 'medicine', trainingStage: null, canEdit: true },
  ]) {
    assert.equal(context.renderAdminUserTrainingStageField(args), '');
  }
});

test('saveAdminUserTrainingStage sets stage, updates last term and courses, and keeps edited name/phone in draft', async () => {
  const userId = '11111111-1111-4111-8111-111111111111';
  const client = makeFakeClient((call) => {
    if (call.table === 'profiles') {
      return {
        data: {
          id: userId,
          training_stage: 'intern_1',
          academic_year: 5,
          academic_semester: 2,
          updated_at: '2026-11-19T18:50:00.000Z',
        },
        error: null,
      };
    }
    if (call.table === 'user_course_enrollments') {
      return {
        data: [
          { course_id: 'c1', courses: { course_name: 'Medicine', is_active: true } },
          { course_id: 'c2', courses: { course_name: 'Surgery', is_active: true } },
          { course_id: 'c3', courses: { course_name: 'Pediatrics', is_active: false } },
        ],
        error: null,
      };
    }
    return { data: null, error: null };
  });

  const h = harness({
    client,
    users: [{
      id: userId,
      role: 'student',
      name: 'Ahmed Ali',
      phone: '+201001112223',
      college: 'medicine',
      academicYear: 3,
      academicSemester: 1,
      trainingStage: null,
      enrolledCourses: ['Pathology', 'Pharmacology'],
      assignedCourses: ['Pathology', 'Pharmacology'],
    }],
    drafts: {
      [userId]: {
        name: 'Dr. Ahmed Ali',
        phone: '+201001112223',
        academicYear: '3',
        academicSemester: '1',
      },
    },
  });

  const result = await h.context.saveAdminUserTrainingStage(userId, 'intern_1');
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { ok: true, stage: 'intern_1' });
  assert.equal(h.savedLocalCalls.length, 1);

  const savedUser = h.getUsersNow()[0];
  assert.equal(savedUser.trainingStage, 'intern_1');
  assert.equal(savedUser.academicYear, 5);
  assert.equal(savedUser.academicSemester, 2);
  assert.deepEqual(JSON.parse(JSON.stringify(savedUser.enrolledCourses)), ['Medicine', 'Surgery']);
  assert.deepEqual(JSON.parse(JSON.stringify(savedUser.assignedCourses)), ['Medicine', 'Surgery']);
  assert.equal(savedUser.profileUpdatedAt, '2026-11-19T18:50:00.000Z');
  assert.ok(h.clearedOverrides.includes(userId));
  assert.ok(h.relationalSync.lastUserLocalWriteAt > 0);

  // Draft preserves edited name, while year/semester sync to the server's new last term.
  assert.deepEqual(JSON.parse(JSON.stringify(h.state.adminUserEnrollmentDrafts[userId])), {
    name: 'Dr. Ahmed Ali',
    phone: '+201001112223',
    academicYear: '5',
    academicSemester: '2',
  });
  const view = h.context.getAdminUserEnrollmentViewModel(savedUser);
  assert.equal(view.account.name, 'Dr. Ahmed Ali');
  assert.equal(view.account.academicYear, 5);
  assert.equal(view.account.academicSemester, 2);

  assert.equal(h.logs[0].kind, 'admin.user_training_stage_changed');
  assert.equal(h.toasts.at(-1), 'Stage set: Intern year 1 (Imtiyaz)');
  assert.equal(h.state.skipNextRouteAnimation, true);
  assert.equal(h.getRenders(), 1);
  assert.equal(h.getMutationDepth(), 0);
  assert.equal(h.getMaxMutationDepth(), 1);
});

test('saveAdminUserTrainingStage drops a term-only draft and supports clearing stage', async () => {
  const userId = '22222222-2222-4222-8222-222222222222';
  const client = makeFakeClient((call) => {
    const updatePayload = call.ops.find(([op]) => op === 'update')?.[1];
    if (call.table === 'profiles' && updatePayload?.training_stage === 'senior_resident') {
      return {
        data: {
          id: userId,
          training_stage: 'senior_resident',
          academic_year: 5,
          academic_semester: 2,
          updated_at: '2026-11-19T18:51:00.000Z',
        },
        error: null,
      };
    }
    if (call.table === 'profiles' && updatePayload?.training_stage === null) {
      return {
        data: {
          id: userId,
          training_stage: null,
          academic_year: 5,
          academic_semester: 2,
          updated_at: '2026-11-19T18:52:00.000Z',
        },
        error: null,
      };
    }
    if (call.table === 'user_course_enrollments') {
      return { data: [], error: null };
    }
    return { data: null, error: null };
  });

  const h = harness({
    client,
    users: [{
      id: userId,
      role: 'student',
      name: 'Sara',
      phone: '+201001112224',
      college: 'medicine',
      academicYear: 4,
      academicSemester: 1,
      trainingStage: null,
      enrolledCourses: ['Medicine'],
      assignedCourses: ['Medicine'],
    }],
    drafts: {
      [userId]: {
        name: 'Sara',
        phone: '+201001112224',
        academicYear: '3',
        academicSemester: '2',
      },
    },
  });

  const setResult = await h.context.saveAdminUserTrainingStage(userId, 'senior_resident');
  assert.deepEqual(JSON.parse(JSON.stringify(setResult)), { ok: true, stage: 'senior_resident' });
  assert.equal(h.state.adminUserEnrollmentDrafts[userId], undefined);

  const clearResult = await h.context.saveAdminUserTrainingStage(userId, '');
  assert.deepEqual(JSON.parse(JSON.stringify(clearResult)), { ok: true, stage: null });
  assert.equal(h.getUsersNow()[0].trainingStage, null);
  assert.equal(h.toasts.at(-1), 'Stage cleared');
  assert.equal(client.calls.filter((call) => call.table === 'profiles')[1].ops[0][1].training_stage, null);
});

test('saveAdminUserTrainingStage handles failures cleanly without mutating state or leaking mutation count', async () => {
  const userId = '33333333-3333-4333-8333-333333333333';
  const baseUser = {
    id: userId,
    role: 'student',
    name: 'Omar',
    college: 'medicine',
    academicYear: 5,
    academicSemester: 2,
    trainingStage: 'intern_1',
  };

  for (const scenario of [
    {
      name: 'non-UUID account',
      users: [{ ...baseUser, id: 'local-only-id' }],
      userId: 'local-only-id',
      client: makeFakeClient(() => ({ data: null, error: null })),
      expectedToast: /not on the server/,
      expectedStage: 'intern_1',
    },
    {
      name: 'server error',
      users: [baseUser],
      userId,
      client: makeFakeClient(() => ({ data: null, error: { message: 'forbidden' } })),
      expectedToast: /Stage not saved: forbidden/,
      expectedStage: 'intern_1',
    },
    {
      name: 'empty data (no permission)',
      users: [baseUser],
      userId,
      client: makeFakeClient(() => ({ data: null, error: null })),
      expectedToast: /Stage not saved: no permission/,
      expectedStage: 'intern_1',
    },
    {
      name: 'timeout / rejection',
      users: [baseUser],
      userId,
      client: makeFakeClient(() => Promise.reject(new Error('network down'))),
      expectedToast: /Stage not saved: network down/,
      expectedStage: 'intern_1',
    },
  ]) {
    const h = harness({ client: scenario.client, users: scenario.users });
    const result = await h.context.saveAdminUserTrainingStage(scenario.userId, 'intern_2');
    assert.deepEqual(
      JSON.parse(JSON.stringify(result)),
      { ok: false, stage: scenario.expectedStage },
      scenario.name,
    );
    assert.match(h.toasts.at(-1), scenario.expectedToast, scenario.name);
    assert.equal(h.getUsersNow()[0].trainingStage, scenario.expectedStage, scenario.name);
    assert.equal(h.savedLocalCalls.length, 0, scenario.name);
    assert.equal(h.getRenders(), 0, scenario.name);
    assert.equal(h.getMutationDepth(), 0, scenario.name);
  }
});
