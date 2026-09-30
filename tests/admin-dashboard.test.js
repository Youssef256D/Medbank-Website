const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const helperStart = mainSource.indexOf('// Admin dashboard summary helpers.');
const helperEnd = mainSource.indexOf('function buildAdminUserStatistics', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'admin dashboard helper markers moved');

const context = vm.createContext({ Date, Number, Object, Array, String });
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
