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
  this.api = { ADMIN_AREAS, ADMIN_AREA_IDS, ADMIN_PERMISSIONS, ADMIN_PERMISSION_IDS, ADMIN_PAGE_AREAS, ADMIN_PAGE_PERMISSIONS, ADMIN_SUPER_ONLY_PAGES, normalizeAdminAccess, buildAdminAccessRow, adminAccessHasArea, adminAccessCan, canAdminAccessPage, describeAdminAccess };`,
  context,
);
const api = context.api;

const PERMISSIONS_MIGRATION = fs.readFileSync('supabase/migrations/20260930030000_admin_permission_areas.sql', 'utf8');
const ENFORCEMENT_MIGRATION = fs.readFileSync('supabase/migrations/20260930030100_admin_area_enforcement.sql', 'utf8');
const ACTIONS_MIGRATION = fs.readFileSync('supabase/migrations/20261009235000_admin_action_permissions.sql', 'utf8');

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

test('the website actions are exactly the actions the database allows', () => {
  const check = ACTIONS_MIGRATION.match(/permissions <@ array\[([^\]]+)\]/);
  assert.ok(check, 'permissions check constraint not found');
  const dbActions = check[1].split(',').map((entry) => entry.trim().replace(/'/g, ''));
  assert.deepEqual([...api.ADMIN_PERMISSION_IDS], dbActions);
  for (const permission of api.ADMIN_PERMISSIONS) {
    assert.ok(api.ADMIN_AREA_IDS.includes(permission.area), permission.id);
    // The database derives the area from the prefix.
    const prefixArea = { users: 'people', mcq: 'mcq', video_courses: 'video_courses', messaging: 'messaging', system: 'system' }[permission.id.split('.')[0]];
    assert.equal(prefixArea, permission.area, permission.id);
  }
});

test('a row without permissions keeps every action in its areas', () => {
  const access = api.normalizeAdminAccess({ is_super: false, areas: ['people'] });
  assert.equal(api.adminAccessCan(access, 'users.create'), true);
  assert.equal(api.adminAccessCan(access, 'users.delete'), true);
  assert.equal(api.adminAccessCan(access, 'mcq.questions_edit'), false);
});

test('single ticked actions decide buttons and pages', () => {
  const access = api.normalizeAdminAccess({
    is_super: false,
    areas: ['people', 'mcq'],
    permissions: ['users.create', 'mcq.questions_edit', 'messaging.popups'],
  });
  assert.equal(api.adminAccessCan(access, 'users.create'), true);
  assert.equal(api.adminAccessCan(access, 'users.delete'), false);
  assert.equal(api.adminAccessCan(access, 'mcq.questions_edit'), true);
  assert.equal(api.adminAccessCan(access, 'mcq.questions_delete'), false);
  // An action outside the admin's areas does not count.
  assert.equal(api.adminAccessCan(access, 'messaging.popups'), false);
  assert.equal(api.canAdminAccessPage(access, 'users'), true);
  assert.equal(api.canAdminAccessPage(access, 'questions'), true);
  assert.equal(api.canAdminAccessPage(access, 'organizations'), false);
  assert.equal(api.canAdminAccessPage(access, 'bulk-import'), false);
  assert.equal(api.canAdminAccessPage(access, 'popups'), false);
  assert.equal(api.describeAdminAccess(access), 'People (1/6), MCQ Bank (1/5)');
});

test('saving derives areas from the ticked actions', () => {
  assert.deepEqual(
    JSON.parse(JSON.stringify(api.buildAdminAccessRow({ isSuper: false, permissions: ['mcq.bulk_import', 'users.edit', 'bogus'] }))),
    { is_super: false, areas: ['people', 'mcq'], permissions: ['users.edit', 'mcq.bulk_import'] },
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(api.buildAdminAccessRow({ isSuper: true, permissions: [] }))),
    { is_super: true, areas: [...api.ADMIN_AREA_IDS], permissions: null },
  );
});

test('every area page lists the actions that open it', () => {
  for (const page of Object.keys(api.ADMIN_PAGE_AREAS)) {
    const permissions = api.ADMIN_PAGE_PERMISSIONS[page];
    assert.ok(Array.isArray(permissions) && permissions.length, page);
    for (const permission of permissions) {
      assert.equal(api.ADMIN_PERMISSIONS.find((entry) => entry.id === permission)?.area, api.ADMIN_PAGE_AREAS[page], `${page}: ${permission}`);
    }
  }
});

test('the action migration adds triggers only and never touches existing policies', () => {
  assert.doesNotMatch(ACTIONS_MIGRATION, /\b(create|alter|drop) policy\b/i);
  assert.match(ACTIONS_MIGRATION, /add column if not exists permissions text\[\]/);
  // Existing rows keep null = every action in their areas.
  assert.doesNotMatch(ACTIONS_MIGRATION, /update public\.admin_permissions/i);
  assert.match(ACTIONS_MIGRATION, /pg_trigger_depth\(\) > 1/);
});

test('every admin Edge Function checks its own action', () => {
  const expected = {
    'admin-create-user': 'users.create',
    'admin-delete-user': 'users.delete',
    'admin-set-user-password': 'users.password',
    'admin-set-user-access': 'users.access',
  };
  for (const [name, permission] of Object.entries(expected)) {
    const source = fs.readFileSync(`supabase/functions/${name}/index.ts`, 'utf8');
    assert.match(source, new RegExp(`adminCan\\(adminAccess, "${permission.replace('.', '\\.')}"\\)`), name);
  }
});
