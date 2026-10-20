const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const helperStart = mainSource.indexOf('// Admin dashboard summary helpers.');
const helperEnd = mainSource.indexOf('function buildAdminUserStatistics', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'admin dashboard helper markers moved');

const context = vm.createContext({ Date, Number, Object, Array, String, Set });
vm.runInContext(mainSource.slice(helperStart, helperEnd), context);

test('dashboard student summary follows approval truth and reports the requested buckets', () => {
  const nowMs = Date.parse('2026-09-29T12:00:00.000Z');
  const users = [
    {
      role: 'student', academicYear: 1, createdAt: '2026-09-28T10:00:00.000Z',
      isApproved: true, approvalTruth: false, missing: ['phone number'],
    },
    {
      role: 'student', academicYear: 2, createdAt: '2026-09-20T08:00:00.000Z',
      isApproved: false, approvalTruth: false, missing: ['phone number', 'semester'],
    },
    {
      role: 'student', academicYear: 5, createdAt: '2026-09-25T09:00:00.000Z',
      isApproved: true, approvalTruth: true, missing: [],
    },
    {
      role: 'creator', academicYear: 4, createdAt: '2026-09-28T09:00:00.000Z',
      isApproved: false, approvalTruth: false, missing: ['phone number'],
    },
  ];

  const summary = context.buildAdminDashboardUserSnapshot(users, nowMs, {
    isApproved: (user) => user.approvalTruth,
    getMissingFields: (user) => user.missing,
    getCreatedAtMs: (user) => Date.parse(user.createdAt),
    normalizeAcademicYear: (value) => {
      const year = Number(value);
      return Number.isInteger(year) && year >= 1 && year <= 5 ? year : null;
    },
  });

  assert.equal(summary.totalStudents, 3);
  assert.equal(summary.pendingApprovalCount, 2);
  assert.equal(summary.pendingMissingPhoneCount, 2);
  assert.equal(summary.oldestPendingCreatedAtMs, Date.parse('2026-09-20T08:00:00.000Z'));
  assert.equal(summary.newStudentsLast7Days, 2);
  assert.deepEqual(JSON.parse(JSON.stringify(summary.academicYearCounts)), {
    1: 1, 2: 1, 3: 0, 4: 0, 5: 1,
  });
});

test('dashboard count formatting keeps zero visible and unknown counts calm', () => {
  assert.equal(context.formatAdminCount(0), '0');
  assert.equal(context.formatAdminCount(null), '—');
  assert.equal(context.formatAdminCount(undefined), '—');
  assert.equal(context.formatAdminCount(null, { loading: true }), '…');
  assert.equal(context.formatAdminCount(Number.NaN), '—');
  assert.equal(context.sumAdminDashboardCounts(0, 0), 0);
  assert.equal(context.sumAdminDashboardCounts(null, 2), null);
});

test('dashboard year usage counts students, approval and activity per academic year', () => {
  const users = [
    { id: 'a', role: 'student', academicYear: 1, ok: true },
    { id: 'b', role: 'student', academicYear: 1, ok: false },
    { id: 'c', role: 'student', academicYear: 5, ok: true, aliases: ['c', 'c-profile'] },
    { id: 'd', role: 'student', academicYear: null, ok: true },
    { id: 'e', role: 'admin', academicYear: 1, ok: true },
  ];
  const usage = context.buildAdminDashboardYearUsage(users, {
    activeLast7Days: new Set(['a']),
    activeLast30Days: ['a', 'c-profile', 'e'],
    onlineNow: null,
  }, {
    isApproved: (user) => user.ok,
    normalizeAcademicYear: (value) => {
      const year = Number(value);
      return value !== null && Number.isInteger(year) && year >= 1 && year <= 5 ? year : null;
    },
    getIds: (user) => user.aliases || [user.id],
  });

  const plain = JSON.parse(JSON.stringify(usage));
  assert.equal(plain.rows.length, 6);
  assert.deepEqual(plain.rows[0], {
    year: 1, label: 'Year 1', students: 2, approved: 1, activeLast7Days: 1, activeLast30Days: 1, onlineNow: null,
  });
  assert.equal(plain.rows[4].activeLast30Days, 1);
  assert.equal(plain.rows[5].label, 'Year not set');
  assert.equal(plain.rows[5].students, 1);
  assert.equal(plain.totals.students, 4);
  assert.equal(plain.totals.approved, 3);
  assert.equal(plain.totals.activeLast30Days, 2);
  assert.equal(plain.totals.onlineNow, null);
});

test('dashboard channel usage splits website and app students per period', () => {
  const nowMs = Date.parse('2026-10-20T12:00:00.000Z');
  const ago = (hours) => new Date(nowMs - hours * 60 * 60 * 1000).toISOString();
  const users = [
    { id: 'a', role: 'student' },
    { id: 'b', role: 'student', aliases: ['b', 'b-profile'] },
    { id: 'c', role: 'student' },
    { id: 'd', role: 'student' },
    { id: 'admin', role: 'admin' },
  ];
  const usage = context.buildAdminDashboardChannelUsage(users, {
    websiteVisits: [
      { user_id: 'a', last_seen_at: ago(2) },
      { user_id: 'b-profile', last_seen_at: ago(24 * 5) },
      { user_id: 'admin', last_seen_at: ago(1) },
    ],
    appDevices: [
      { user_id: 'b', platform: 'iOS', registered_at: ago(24 * 20), last_seen_at: ago(3) },
      { user_id: 'c', platform: 'android', registered_at: ago(24 * 2), last_seen_at: ago(24 * 10) },
      { user_id: 'admin', platform: 'android', registered_at: ago(5), last_seen_at: ago(1) },
    ],
  }, nowMs, { getIds: (user) => user.aliases || [user.id] });

  const plain = JSON.parse(JSON.stringify(usage));
  assert.equal(plain.registeredStudents, 4);
  assert.deepEqual(plain.installs, {
    total: 2, android: 1, ios: 1, other: 0, newLast7Days: 1,
    trackingSinceMs: nowMs - 20 * 24 * 60 * 60 * 1000,
  });
  const [day, week, month] = plain.windows;
  assert.deepEqual(
    [day.website, day.app, day.both, day.websiteOnly, day.appOnly, day.total],
    [1, 1, 0, 1, 1, 2],
  );
  assert.deepEqual(
    [week.website, week.app, week.both, week.websiteOnly, week.appOnly, week.total],
    [2, 1, 1, 1, 0, 2],
  );
  assert.equal(month.app, 2);
  assert.equal(month.total, 3);

  const failed = context.buildAdminDashboardChannelUsage(users, { websiteVisits: null, appDevices: [] }, nowMs, {
    getIds: (user) => [user.id],
  });
  assert.equal(failed.windows[0].website, null);
  assert.equal(failed.windows[0].total, null);
  assert.equal(failed.installs.total, 0);
});
