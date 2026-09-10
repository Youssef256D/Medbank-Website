const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const utils = require('../app-popups-utils.js');
const valid = (overrides = {}) => ({ title: 'Announcement', audience_role: 'all', display_rule: 'once', priority: 0, ...overrides });
const now = '2026-09-10T12:00:00Z';
for (const [name, popup, expected] of [
  ['no window', { is_active: true }, 'Live'],
  ['future start', { is_active: true, starts_at: '2026-09-11T00:00:00Z' }, 'Scheduled'],
  ['past end', { is_active: true, ends_at: '2026-09-09T00:00:00Z' }, 'Ended'],
  ['inactive inside window', { is_active: false, starts_at: '2026-09-09T00:00:00Z', ends_at: '2026-09-11T00:00:00Z' }, 'Inactive'],
  ['start inclusive', { is_active: true, starts_at: now }, 'Live'],
  ['end exclusive', { is_active: true, ends_at: now }, 'Ended'],
  ['inactive overrides ended', { is_active: false, ends_at: now }, 'Inactive'],
]) test(`state: ${name}`, () => assert.equal(utils.resolvePopupCampaignState(popup, now), expected));

test('exact route vocabulary and normalization', () => {
  assert.deepEqual(utils.POPUP_TARGET_ROUTES, ['app-launcher', 'dashboard', 'create-test', 'analytics', 'video-courses', 'profile', 'notifications']);
  assert.equal(utils.normalizePopupTargetRoute(' CREATE-TEST '), 'create-test');
  assert.equal(utils.normalizePopupTargetRoute('courses'), null);
  assert.equal(utils.normalizePopupTargetRoute(''), null);
  assert.equal(utils.validatePopupCampaign(valid({ target_route: 'https://evil.example' })).ok, false);
});
for (const route of [null, ...utils.POPUP_TARGET_ROUTES]) test(`context validation: ${route || 'no destination'}`, () => {
  assert.equal(utils.validatePopupCampaign(valid({ target_route: route })).ok, true);
  assert.equal(utils.validatePopupCampaign(valid({ target_route: route, target_mcq_subject: 'Anatomy' })).ok, route === 'create-test');
  assert.equal(utils.validatePopupCampaign(valid({ target_route: route, target_mcq_subject: 'Anatomy', target_mcq_topic: 'Head' })).ok, route === 'create-test');
  assert.equal(utils.validatePopupCampaign(valid({ target_route: route, target_mcq_topic: 'Head' })).ok, false);
  assert.equal(utils.validatePopupCampaign(valid({ target_route: route, target_video_course_id: 'course-id' })).ok, route === 'video-courses');
});
test('image-only adverts require image and title', () => {
  assert.equal(utils.validatePopupCampaign(valid({ image_fills_card: true })).ok, false);
  assert.equal(utils.validatePopupCampaign(valid({ image_fills_card: true, image_url: 'https://example.com/a.png' })).ok, true);
  assert.equal(utils.validatePopupCampaign(valid({ title: ' ', image_fills_card: true, image_url: 'https://example.com/a.png' })).ok, false);
  assert.equal(utils.validatePopupCampaign(valid({ image_url: ['javascript', 'alert(1)'].join(':') })).ok, false);
});
test('window must be ordered and dates valid', () => {
  for (const end of [now, '2026-09-09T00:00:00Z', 'bad']) assert.equal(utils.validatePopupCampaign(valid({ starts_at: now, ends_at: end })).ok, false);
  assert.equal(utils.validatePopupCampaign(valid({ starts_at: now, ends_at: '2026-09-11T00:00:00Z' })).ok, true);
  assert.equal(utils.validatePopupCampaign(valid({ starts_at: now })).ok, true);
});
test('CHECK lists, academic year and integer priority', () => {
  for (const year of [null, 1, 2, 3, 4, 5]) assert.equal(utils.validatePopupCampaign(valid({ audience_academic_year: year })).ok, true);
  for (const year of [0, 6, 1.5, '2']) assert.equal(utils.validatePopupCampaign(valid({ audience_academic_year: year })).ok, false);
  for (const role of utils.POPUP_AUDIENCE_ROLES) assert.equal(utils.validatePopupCampaign(valid({ audience_role: role })).ok, true);
  for (const rule of utils.POPUP_DISPLAY_RULES) assert.equal(utils.validatePopupCampaign(valid({ display_rule: rule })).ok, true);
  for (const invalid of [{ audience_role: 'owner' }, { display_rule: 'weekly' }, { priority: NaN }, { priority: 2.5 }, { priority: 2147483648 }]) assert.equal(utils.validatePopupCampaign(valid(invalid)).ok, false);
});
test('unique account metrics, repeats, overlaps and zero denominator', () => {
  const metrics = utils.aggregatePopupPerformance([
    { popup_id: 'a', seen_count: 8, dismissed_at: now, clicked_at: now },
    { popup_id: 'a', seen_count: 1 },
    { popup_id: 'b', seen_count: 0, dismissed_at: now },
  ]);
  assert.deepEqual(metrics.a, { shown: 2, dismissed: 1, tapped: 1, tapThroughRate: 50 });
  assert.equal(metrics.b.shown, 0);
  assert.equal(metrics.b.tapThroughRate, 0);
});
test('UMD browser namespace and static runtime registrations', () => {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync('app-popups-utils.js', 'utf8'), context);
  assert.equal(context.MedBankAppPopups.resolvePopupCampaignState({ is_active: true }), 'Live');
  const bootstrap = fs.readFileSync('bootstrap.js', 'utf8');
  assert.ok(bootstrap.indexOf('loadScript(`app-popups-utils.js') < bootstrap.indexOf('loadScript(`main.js'));
  assert.match(fs.readFileSync('sw.js', 'utf8'), /app-popups-utils\.js/);
  assert.match(JSON.parse(fs.readFileSync('package.json')).scripts.lint, /app-popups-utils\.js/);
});

// Exercise the actual classic-script admin functions with an isolated browser/client.
const mainSource = fs.readFileSync('main.js', 'utf8');
const adminSource = mainSource.slice(mainSource.indexOf('// Mobile pop-up administration.'), mainSource.indexOf('function renderAdminDataSidebarNav'));
function adminHarness(overrides = {}) {
  const state = { route: 'admin', adminPage: 'popups', adminPopups: [], adminPopupMetrics: {}, adminPopupsLoadedAt: 1,
    adminNotificationVideoCourses: [], adminCoursesPlatformCourses: [], adminPopupDraft: null };
  const context = vm.createContext({ state, MedBankAppPopups: utils, Date, console,
    getCurrentUser: () => ({ id: 'admin-id', role: 'admin' }), getCoursesPlatformClient: () => ({}),
    runRelationalQueryWithTimeout: async (query) => { const result = await query; if (result.error) throw result.error; return result.data; },
    isMissingRelationError: (error) => ['42P01', 'PGRST205'].includes(error.code),
    isStorageBucketMissingError: (error) => /bucket not found/i.test(error.message),
    loadAdminNotificationVideoCourseOptions: async () => true, render: () => {}, toast: () => {},
    // Mirrors main.js escapeHtml() EXACTLY, including its String(value || "")
    // coercion. A stub using ?? here is more forgiving than production and
    // hides every falsy-value rendering bug, which is how a raw 0 shipped as a
    // blank cell. Keep these two in step.
    escapeHtml: (value) => String(value || '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]),
    QBANK_COURSE_TOPICS: { Anatomy: ['Head'] }, getCoursePlatformCourseTitle: (course) => course.course_name,
    crypto: { randomUUID: () => 'unique-file' }, SUPABASE_QUERY_TIMEOUT_MS: 1000,
    runWithTimeoutResult: async (query) => query, ...overrides,
  });
  vm.runInContext(adminSource, context);
  return context;
}
test('missing tables produce calm panel and disabled editor, without raw database errors', async () => {
  const h = adminHarness({ getCoursesPlatformClient: () => ({ from() { throw { code: '42P01', message: 'RAW DATABASE ERROR' }; } }) });
  h.state.adminPopupDraft = h.newAdminPopupDraft();
  await h.loadAdminPopups();
  assert.equal(h.state.adminPopupsMissing, true);
  assert.equal(h.state.adminPopupsLoading, false);
  const html = h.renderAdminPopupsSection();
  assert.match(html, /has not been applied/);
  assert.match(html, /<fieldset disabled>/);
  assert.doesNotMatch(html, /RAW DATABASE ERROR/);
});
test('absent optional global disables tools without crashing the admin page', () => {
  const h = adminHarness({ MedBankAppPopups: undefined });
  assert.match(h.renderAdminPopupsSection(), /Pop-up tools could not load/);
});
test('paginated reads continue past partial pages and use stable ordering', async () => {
  const calls = [];
  const client = { from(table) {
    return { select() { return this; }, order(column) { calls.push(column); return this; }, range(start, end) {
      calls.push([table, start, end]);
      return Promise.resolve({ data: start < 3 ? [{ id: start }] : [] });
    } };
  } };
  const h = adminHarness();
  const rows = await h.readAllAdminPopupRows(client, 'app_popup_views', '*');
  assert.equal(rows.length, 3);
  assert.equal(calls.filter((value) => value === 'user_id').length, 4);
});
test('upload uses public URL, unique path and never upserts', async () => {
  let options;
  const h = adminHarness({ getCoursesPlatformClient: () => ({ storage: { from(bucket) {
    assert.equal(bucket, 'popup-images');
    return { upload: async (path, file, config) => { options = config; assert.match(path, /campaigns\/unique-file.png/); return { data: {} }; },
      getPublicUrl: () => ({ data: { publicUrl: 'https://example.com/public/image.png' } }) };
  } } }) });
  assert.equal(await h.uploadAdminPopupImage({ size: 100, type: 'image/png' }), 'https://example.com/public/image.png');
  assert.equal(options.upsert, false);
  await assert.rejects(h.uploadAdminPopupImage({ size: 100, type: 'image/svg+xml' }), /PNG, JPEG or WebP/);
});
test('missing bucket upload explains migration and preserves draft', async () => {
  const h = adminHarness({ getCoursesPlatformClient: () => ({ storage: { from: () => ({ upload: async () => ({ error: { message: 'Bucket not found' } }) }) } }) });
  h.state.adminPopupDraft = h.newAdminPopupDraft();
  await assert.rejects(h.uploadAdminPopupImage({ size: 100, type: 'image/png' }), /Apply the pop-up migration/);
  assert.equal(h.state.adminPopupDraft.image_url, '');
});
test('preview escapes text, hides advert copy and action, and rejects unsafe image URLs', () => {
  const h = adminHarness();
  const draft = { ...h.newAdminPopupDraft(), title: '<script>bad()</script>', body: '<img onerror=bad()>', target_route: 'profile' };
  const normal = h.renderAdminPopupPreview(draft);
  assert.match(normal, /&lt;script&gt;/);
  assert.doesNotMatch(normal, /<script>/);
  assert.match(normal, /class="btn">Open/);
  const advert = h.renderAdminPopupPreview({ ...draft, image_fills_card: true, image_url: ['javascript', 'bad()'].join(':') });
  assert.doesNotMatch(advert, /class="btn"|<h4>|src="javascript:/);
});
function wiredEditor(draftOverrides = {}, overrides = {}) {
  const listeners = {};
  const controls = {};
  const form = { elements: controls, addEventListener: (event, handler) => { listeners[event] = handler; } };
  const section = { querySelector: (selector) => selector === '#admin-popup-form' ? form : null, querySelectorAll: () => [] };
  const h = adminHarness({ appEl: { querySelector: () => section }, confirm: () => false,
    nowISO: () => now, getNotificationVideoCourseById: () => true, ...overrides });
  h.state.adminPopupDraft = { ...h.newAdminPopupDraft(), title: 'Campaign', ...draftOverrides };
  for (const [key, value] of Object.entries(h.state.adminPopupDraft)) controls[key] = { value: String(value ?? ''), checked: !!value };
  controls.artwork = { addEventListener: () => {} };
  h.wireAdminPopups();
  return { h, listeners, controls };
}
test('saving a Live campaign requires confirmation and cancellation performs no write', () => {
  let confirmations = 0;
  const { h, listeners } = wiredEditor({ id: 'live', is_active: true }, { confirm: () => { confirmations++; return false; }, getCoursesPlatformClient: () => { throw new Error('must not write'); } });
  h.state.adminPopups = [{ id: 'live', is_active: true }];
  listeners.submit({ preventDefault() {} });
  assert.equal(confirmations, 1);
  assert.equal(h.state.adminPopupSaving, undefined);
});
test('save sends only allowed campaign columns with null empty context and authenticated creator', async () => {
  let payload;
  const { h, listeners } = wiredEditor({ arbitrary: 'must not leak' }, {
    getCoursesPlatformClient: () => ({ from: (table) => {
      assert.equal(table, 'app_popups');
      return { insert: (data) => { payload = data; return { select: async () => ({ data: [{ id: 'created' }] }) }; } };
    } }),
  });
  h.loadAdminPopups = async () => {};
  listeners.submit({ preventDefault() {} });
  await new Promise((resolve) => { setImmediate(resolve); });
  assert.equal(payload.created_by, 'admin-id');
  assert.equal(payload.target_route, null);
  assert.equal(payload.target_mcq_topic, null);
  assert.equal(payload.arbitrary, undefined);
  assert.equal(payload.is_active, false);
  assert.equal(h.state.adminPopupDraft, null);
});
test('mutation failure preserves draft and releases busy state', async () => {
  const h = adminHarness();
  h.state.adminPopupDraft = h.newAdminPopupDraft();
  await h.runAdminPopupMutation(async () => { throw new Error('network down'); });
  assert.ok(h.state.adminPopupDraft);
  assert.equal(h.state.adminPopupSaving, false);
});

test('zero priority and zero impressions render as 0, not blank cells', () => {
  const h = adminHarness();
  h.state.adminPopups = [{ id: 'z', title: 'New', created_at: now, audience_role: 'all', priority: 0, is_active: false }];
  const html = h.renderAdminPopupsSection();
  // escapeHtml() maps any falsy value to "", so a raw 0 would silently vanish.
  assert.match(html, /<td>0<\/td><td>0<\/td><td>0<\/td><td>0<\/td>/);
  h.state.adminPopupDraft = { ...h.newAdminPopupDraft(), title: 'Draft' };
  assert.match(h.renderAdminPopupsSection(), /name="priority"[^>]*value="0"/);
});
