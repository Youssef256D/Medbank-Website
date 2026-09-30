const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const start = mainSource.indexOf('// Admin layers: area helpers.');
const end = mainSource.indexOf('// End admin layers helpers.', start);
assert.ok(start >= 0 && end > start, 'admin layers helper markers moved');

const context = vm.createContext({});
vm.runInContext(
  `${mainSource.slice(start, end)}
  this.api = { ADMIN_AREAS, ADMIN_AREA_IDS, ADMIN_PAGE_AREAS, ADMIN_SUPER_ONLY_PAGES, normalizeAdminAccess, adminAccessHasArea, canAdminAccessPage, describeAdminAccess };`,
  context,
);
const api = context.api;

const PERMISSIONS_MIGRATION = fs.readFileSync('supabase/migrations/20260930030000_admin_permission_areas.sql', 'utf8');
const ENFORCEMENT_MIGRATION = fs.readFileSync('supabase/migrations/20260930030100_admin_area_enforcement.sql', 'utf8');

test('the website areas are exactly the areas the database allows', () => {
  const check = PERMISSIONS_MIGRATION.match(/areas <@ array\[([^\]]+)\]/);
  assert.ok(check, 'areas check constraint not found');
  const dbAreas = check[1].split(',').map((entry) => entry.trim().replace(/'/g, ''));
  assert.deepEqual([...api.ADMIN_AREA_IDS], dbAreas);
});

test('a super admin sees every page', () => {
  const access = api.normalizeAdminAccess({ is_super: true, areas: [] });
  assert.equal(access.isSuper, true);
  assert.deepEqual([...access.areas], [...api.ADMIN_AREA_IDS]);
  for (const page of ['dashboard', 'users', 'questions', 'video-courses', 'popups', 'logs', 'site-access', 'ai-agents', 'admin-access']) {
    assert.equal(api.canAdminAccessPage(access, page), true, page);
  }
  assert.equal(api.describeAdminAccess(access), 'Super admin');
});

test('a limited admin sees the Dashboard and their areas only', () => {
  const access = api.normalizeAdminAccess({ is_super: false, areas: ['mcq', 'messaging', 'bogus'] });
  assert.deepEqual([...access.areas], ['mcq', 'messaging']);
  assert.equal(api.canAdminAccessPage(access, 'dashboard'), true);
  assert.equal(api.canAdminAccessPage(access, 'questions'), true);
  assert.equal(api.canAdminAccessPage(access, 'bulk-import'), true);
  assert.equal(api.canAdminAccessPage(access, 'notifications'), true);
  assert.equal(api.canAdminAccessPage(access, 'users'), false);
  assert.equal(api.canAdminAccessPage(access, 'video-courses'), false);
  assert.equal(api.canAdminAccessPage(access, 'logs'), false);
  // Super-only pages stay hidden even with every area.
  const allAreas = api.normalizeAdminAccess({ is_super: false, areas: [...api.ADMIN_AREA_IDS] });
  for (const page of ['site-access', 'ai-agents', 'admin-access']) {
    assert.equal(api.canAdminAccessPage(allAreas, page), false, page);
  }
  // An unknown page is super-only.
  assert.equal(api.canAdminAccessPage(allAreas, 'some-new-page'), false);
  assert.equal(api.describeAdminAccess(access), 'MCQ Bank, Messaging');
});

test('no row means no areas; a missing table or unloaded access hides nothing', () => {
  const none = api.normalizeAdminAccess(null);
  assert.equal(none.isSuper, false);
  assert.deepEqual([...none.areas], []);
  assert.equal(api.canAdminAccessPage(none, 'users'), false);
  assert.equal(api.describeAdminAccess(none), 'No areas yet');

  const legacy = api.normalizeAdminAccess(null, { tableMissing: true });
  assert.equal(legacy.isSuper, true);
  assert.equal(legacy.legacy, true);

  assert.equal(api.canAdminAccessPage(null, 'admin-access'), true);
  assert.equal(api.adminAccessHasArea(null, 'people'), true);
});

test('every admin page is either in an area, super-only, or the Dashboard', () => {
  const pagesMatch = mainSource.match(/const ADMIN_DATA_PAGES = \[([^\]]+)\]/);
  const pages = [...pagesMatch[1].matchAll(/"([^"]+)"/g)].map((entry) => entry[1]);
  pages.push('video-courses');
  for (const page of pages) {
    const covered = page === 'dashboard' || api.ADMIN_SUPER_ONLY_PAGES.has(page) || Object.hasOwn(api.ADMIN_PAGE_AREAS, page);
    assert.ok(covered, `${page} has no area`);
  }
});

test('the enforcement migration only adds restrictive policies and keeps students and creators out of scope', () => {
  const created = [...ENFORCEMENT_MIGRATION.matchAll(/create policy (\w+)\s+on [\w.]+ as (\w+)/gi)];
  assert.ok(created.length > 0);
  for (const [, name, kind] of created) {
    assert.equal(kind.toLowerCase(), 'restrictive', name);
  }
  assert.match(ENFORCEMENT_MIGRATION, /as restrictive for insert to authenticated with check \(%s\)/);
  assert.doesNotMatch(ENFORCEMENT_MIGRATION, /\balter policy\b/i);
  // Generated drops use %I with a *_area_guard_* / *_super_guard name; named
  // drops must be guard policies too. No existing policy is ever dropped.
  assert.doesNotMatch(ENFORCEMENT_MIGRATION, /drop policy if exists (?!%I|\S*(_area_guard_|_super_guard|_site_maintenance_))/i);
  assert.match(ENFORCEMENT_MIGRATION, /spec\.table_name \|\| '_area_guard_insert'/);
  // Non-admins pass the guard: their rights stay with the existing policies.
  assert.match(PERMISSIONS_MIGRATION, /select not private\.is_admin_user\(\) or private\.admin_has_area\(target_area\)/);
});

test('every current admin is seeded as a super admin', () => {
  assert.match(PERMISSIONS_MIGRATION, /insert into public\.admin_permissions \(user_id, is_super, areas\)\s+select p\.id, true,/);
  assert.match(PERMISSIONS_MIGRATION, /where p\.role::text = 'admin'/);
});
