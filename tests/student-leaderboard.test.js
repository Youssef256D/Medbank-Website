const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const blockStart = mainSource.indexOf('// ── Class leaderboard (student dashboard)');
const blockEnd = mainSource.indexOf('\nfunction renderResumeCard(', blockStart);
assert.ok(blockStart >= 0 && blockEnd > blockStart, 'class leaderboard block markers moved');

function sliceFunction(name) {
  const start = mainSource.indexOf(`\nfunction ${name}(`);
  assert.ok(start >= 0, `${name} not found`);
  const end = mainSource.indexOf('\n}\n', start);
  return mainSource.slice(start, end + 3);
}

function load(rows) {
  const calls = [];
  const context = vm.createContext({
    Date, Number, Object, Array, String, Math, Intl, JSON, Promise, console,
    state: { route: 'dashboard' },
    calls,
    renders: 0,
    render() { context.renders += 1; },
    getRelationalClient: () => ({
      rpc: (name, params) => {
        calls.push({ name, params });
        return Promise.resolve({ data: rows, error: null });
      },
    }),
    runRelationalQueryWithTimeout: async (query) => {
      const { data, error } = await query;
      if (error) throw error;
      return data;
    },
  });
  vm.runInContext([sliceFunction('escapeHtml'), sliceFunction('formatAdminCount'), mainSource.slice(blockStart, blockEnd)].join('\n'), context);
  return context;
}

const flush = () => new Promise((resolve) => {
  setImmediate(resolve);
});

test('the dashboard shows the class board once it arrives', async () => {
  const ctx = load([
    { rank: 1, display_name: 'Mariam K.', points: 12, is_me: false, is_hidden: false },
    { rank: 2, display_name: null, points: 9, is_me: false, is_hidden: true },
    { rank: 3, display_name: 'Youssef A.', points: 1, is_me: true, is_hidden: false },
  ]);
  const user = { id: 'me' };
  assert.equal(ctx.renderDashboardLeaderboard(user), '', 'nothing while loading');
  assert.deepEqual(JSON.parse(JSON.stringify(ctx.calls[0])), {
    name: 'get_mcq_leaderboard',
    params: { p_period: 'week', p_limit: 10 },
  });
  await flush();
  assert.equal(ctx.renders, 1);
  const html = ctx.renderDashboardLeaderboard(user);
  assert.match(html, /#3 in your class/);
  assert.match(html, /Mariam K\./);
  assert.match(html, /<i class="is-hidden-name">Student<\/i>/);
  assert.match(html, /1 point</);
  assert.match(html, /data-leaderboard-show-name checked/);
  assert.equal(ctx.calls.length, 1, 'not asked again within a minute');
});

test('no class means no section', async () => {
  const ctx = load([]);
  ctx.renderDashboardLeaderboard({ id: 'me' });
  await flush();
  assert.equal(ctx.renderDashboardLeaderboard({ id: 'me' }), '');
});

test('an unranked student still sees their place line', async () => {
  const ctx = load([
    { rank: 1, display_name: 'Mariam K.', points: 12, is_me: false, is_hidden: false },
    { rank: null, display_name: 'Youssef A.', points: 0, is_me: true, is_hidden: true },
  ]);
  ctx.renderDashboardLeaderboard({ id: 'me' });
  await flush();
  const html = ctx.renderDashboardLeaderboard({ id: 'me' });
  assert.match(html, /Not on the board yet/);
  assert.doesNotMatch(html, /data-leaderboard-show-name checked/, 'unchecked while hidden');
});
