const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');

function sliceFunction(name) {
  const start = mainSource.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in main.js`);
  const end = mainSource.indexOf('\n}\n', start);
  return mainSource.slice(start, end + 3);
}

const context = vm.createContext({});
vm.runInContext(
  `${sliceFunction('resolveOrganizationCodeStatus')}
  ${sliceFunction('filterOrganizationMembers')}
  this.api = { resolveOrganizationCodeStatus, filterOrganizationMembers };`,
  context,
);
const { resolveOrganizationCodeStatus, filterOrganizationMembers } = context.api;

test('organization code status: revoked beats expired beats used up', () => {
  const now = Date.parse('2026-10-09T12:00:00Z');
  const past = '2026-10-01T00:00:00Z';
  const future = '2026-12-01T00:00:00Z';
  assert.equal(resolveOrganizationCodeStatus({ use_count: 0 }, now), 'active');
  assert.equal(resolveOrganizationCodeStatus({ expires_at: future, max_uses: 5, use_count: 4 }, now), 'active');
  assert.equal(resolveOrganizationCodeStatus({ max_uses: 5, use_count: 5 }, now), 'used_up');
  assert.equal(resolveOrganizationCodeStatus({ expires_at: past, max_uses: 5, use_count: 5 }, now), 'expired');
  assert.equal(resolveOrganizationCodeStatus({ revoked_at: past, expires_at: past }, now), 'revoked');
});

test('organization member search matches name, email and ID', () => {
  const members = [
    { user_id: 'a', profile: { full_name: 'Sara Ali', email: 'sara@example.com', public_user_id: 'MB-0001' } },
    { user_id: 'b', profile: { full_name: 'Omar Hassan', email: 'omar@example.com', public_user_id: 'MB-0002' } },
  ];
  assert.equal(filterOrganizationMembers(members, '').length, 2);
  assert.deepEqual(filterOrganizationMembers(members, 'sara').map((m) => m.user_id), ['a']);
  assert.deepEqual(filterOrganizationMembers(members, 'OMAR@').map((m) => m.user_id), ['b']);
  assert.deepEqual(filterOrganizationMembers(members, 'mb-0002').map((m) => m.user_id), ['b']);
  assert.equal(filterOrganizationMembers(null, 'x').length, 0);
});

test('organizations is a People-area admin page in the nav', () => {
  assert.match(mainSource, /\{ page: "organizations", label: "Organizations" \}/);
  assert.match(mainSource, /organizations: "people",/);
  assert.match(mainSource, /const ADMIN_DATA_PAGES = \[[^\]]*"organizations"/);
});

test('video course queries no longer read the dropped term columns', () => {
  const select = mainSource.match(/const COURSE_PLATFORM_COURSE_SELECT = "([^"]+)"/)[1];
  assert.doesNotMatch(select, /academic_year|academic_semester/);
  assert.doesNotMatch(mainSource, /target_academic_year,target_semester/);
});
