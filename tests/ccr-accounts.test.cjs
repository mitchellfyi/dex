'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const state = require('../scripts/ccr/state.cjs');
const { CredentialStore, AccountBroker, normalizeTokens, normalizeApiKey, providerKind, authHeaders, nativeEnv, normalizeUsage } = require('../scripts/ccr/accounts.cjs');

test('private state rejects symlinks and public permissions', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-state-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const file = path.join(root, 'state.json'); state.write(file, { value: 1 });
  assert.deepEqual(state.read(file), { value: 1 });
  const link = path.join(root, 'link.json'); fs.symlinkSync(file, link);
  assert.throws(() => state.read(link), /unsafe/);
  fs.chmodSync(file, 0o644); assert.throws(() => state.read(file), /unsafe/);
});
test('native login environments are isolated from API keys and other profile homes', () => {
  const env = nativeEnv('openai', '/tmp/selected-account');
  assert.equal(env.CODEX_HOME, '/tmp/selected-account');
  assert.equal(env.ANTHROPIC_API_KEY, undefined);
  assert.equal(env.ANTHROPIC_BASE_URL, undefined);
  assert.equal(nativeEnv('anthropic', '/tmp/second-account').CLAUDE_CONFIG_DIR, '/tmp/second-account');
});
test('API keys and nonrenewable credentials cannot register', () => {
  for (const raw of [{ OPENAI_API_KEY: 'synthetic' }, { tokens: { access_token: 'synthetic' } }, null]) assert.throws(() => normalizeTokens('openai', raw), /OAuth/);
});
test('quota preserves unknown data instead of inventing percentages', () => {
  assert.deepEqual(normalizeUsage('openai', {}).windows, []);
  assert.equal(normalizeUsage('anthropic', { five_hour: { utilization: 42, resets_at: '2026-09-10T12:00:00Z' } }).windows[0].remaining_ratio, 0.58);
  assert.deepEqual(normalizeUsage('anthropic', { five_hour: { utilization: 999 } }).windows, []);
});
test('OpenAI primary quota can be a weekly window', () => {
  const usage = normalizeUsage('openai', { rate_limit: { primary_window: { used_percent: 57, limit_window_seconds: 604800, reset_at: 1789644431 }, secondary_window: null } });
  assert.equal(usage.windows[0].name, 'weekly');
  assert.equal(usage.windows[0].remaining_ratio, 0.43);
  assert.equal(normalizeUsage('openai', { rate_limit: { primary_window: { used_percent: 10, limit_window_seconds: 18000 } } }).windows[0].name, '5h');
});
test('concurrent refresh is shared and rotated credentials survive broker restart', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-refresh-'));
  const prior = process.env.DEX_ROUTER_HOME; process.env.DEX_ROUTER_HOME = dir;
  t.after(() => { if (prior === undefined) delete process.env.DEX_ROUTER_HOME; else process.env.DEX_ROUTER_HOME = prior; fs.rmSync(dir, { recursive: true, force: true }); });
  const store = new CredentialStore('linux'); store.set('a', { access_token: 'synthetic-old', refresh_token: 'synthetic-refresh', expires_at: 0 });
  let calls = 0;
  const broker = new AccountBroker({ store, fetchImpl: async () => { calls++; return Response.json({ access_token: 'synthetic-new', refresh_token: 'synthetic-rotated', expires_in: 3600 }); } });
  const account = { id: 'a', provider: 'openai' };
  const result = await Promise.all(Array.from({ length: 20 }, () => broker.access(account)));
  assert.equal(calls, 1); assert.equal(result[0].refresh_token, 'synthetic-rotated');
  const restarted = new AccountBroker({ store, fetchImpl: async () => { throw new Error('unexpected refresh'); } });
  assert.equal((await restarted.access(account)).access_token, 'synthetic-new');
  assert.equal(fs.statSync(store.file('a')).mode & 0o777, 0o600);
});
test('account refresh never falls back to the global native login', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-missing-'));
  const prior = process.env.DEX_ROUTER_HOME; process.env.DEX_ROUTER_HOME = dir;
  t.after(() => { if (prior === undefined) delete process.env.DEX_ROUTER_HOME; else process.env.DEX_ROUTER_HOME = prior; fs.rmSync(dir, { recursive: true, force: true }); });
  const broker = new AccountBroker({ store: new CredentialStore('linux') });
  await assert.rejects(broker.access({ id: 'missing', provider: 'anthropic' }), /missing/);
});

test('a metered provider authenticates with a key instead of a renewable login', async () => {
  assert.equal(providerKind('openrouter'), 'credit');
  assert.equal(providerKind('anthropic'), 'subscription');
  assert.equal(providerKind('not-a-provider'), 'subscription', 'unknown providers keep the subscription error path');
  const credentials = normalizeTokens('openrouter', { api_key: `sk-or-v1-${'a'.repeat(40)}` });
  assert.equal(credentials.kind, 'api-key');
  assert.equal(credentials.api_key, `sk-or-v1-${'a'.repeat(40)}`);
  assert.throws(() => normalizeApiKey('short'), /API key/);
  assert.throws(() => normalizeApiKey({ accessToken: 'x', refreshToken: 'y' }), /API key/);
  // The OAuth path still refuses a bare key, so a subscription cannot silently
  // become an unrenewable one.
  assert.throws(() => normalizeTokens('anthropic', { access_token: 'only' }), /API keys are not supported/);
  const headers = authHeaders('openrouter', credentials);
  assert.equal(headers.authorization, `Bearer ${credentials.api_key}`);
  assert.equal(headers['anthropic-beta'], undefined);
});

test('a metered key is never refreshed and never expires out from under a route', async () => {
  const store = { get: () => ({ kind: 'api-key', api_key: `sk-or-v1-${'b'.repeat(40)}`, expires_at: Number.MAX_SAFE_INTEGER }), set: () => { throw new Error('must not rewrite a key'); } };
  const broker = new AccountBroker({ store, fetchImpl: async () => { throw new Error('must not call a token endpoint'); } });
  const account = { id: 'metered', provider: 'openrouter' };
  assert.equal((await broker.access(account)).api_key, `sk-or-v1-${'b'.repeat(40)}`);
  // Even a forced refresh has nothing to refresh; it must not discard the key.
  assert.equal((await broker.access(account, true)).api_key, `sk-or-v1-${'b'.repeat(40)}`);
});

test('a spend cap exhausts like a quota and an uncapped account reports no window', () => {
  // The account balance is the cap that actually returns 402; a key can carry
  // no limit of its own and still fail once the account behind it runs dry.
  const spent = normalizeUsage('openrouter', { data: { total_credits: 10, total_usage: 10 } }, 1000);
  // A balance carries what is left of it in money, because it has no reset to report.
  assert.deepEqual(spent.windows, [{ name: 'credit', remaining_ratio: 0, resets_at: null, remaining_amount: 0 }]);
  const partial = normalizeUsage('openrouter', { data: { total_credits: 40, total_usage: 10 } }, 1000);
  assert.equal(partial.windows[0].remaining_ratio, 0.75);
  assert.equal(normalizeUsage('openrouter', { data: { total_credits: 10, total_usage: 12 } }, 1000).windows[0].remaining_ratio, 0,
    'spending past the balance clamps at exhausted, it does not go negative');
  // A key limit is a second, independent cap: either one stops the account.
  // This cap does not reset, so what the key has ever spent is what counts.
  const both = normalizeUsage('openrouter', { data: { total_credits: 10, total_usage: 5, limit: 2, usage: 2 } }, 1000);
  // The key's own cap is this account's near-term limit, so it shares the
  // near-term column rather than adding one to every table.
  assert.deepEqual(both.windows.map(w => [w.name, w.remaining_ratio, w.remaining_amount]),
    [['credit', 0.5, 5], ['spend-limit', 0, 0]]);
  assert.deepEqual(normalizeUsage('openrouter', { data: { total_credits: null, total_usage: 3, limit: null, usage: 1 } }, 1000).windows, [],
    'no cap means no window to exhaust, not a window at zero');
});

test('a cap that resets counts the period it resets on, not what the key ever spent', () => {
  // The live shape that exhausted a healthy account: a key that had spent
  // $15.23 in its life against a $15 daily cap with the day untouched.
  const now = Date.parse('2026-09-21T09:00:00Z');
  const live = { data: { total_credits: 110, total_usage: 17.704526, limit: 15, usage: 15.234826,
    limit_remaining: 15, limit_reset: 'daily', usage_daily: 0, usage_weekly: 0, usage_monthly: 15.234826 } };
  const window = normalizeUsage('openrouter', live, now).windows.find(item => item.name === 'spend-limit');
  assert.equal(window.remaining_ratio, 1, 'the whole daily allowance is still there');
  assert.equal(window.remaining_amount, 15);
  assert.equal(new Date(window.resets_at).toISOString(), '2026-09-22T00:00:00.000Z');

  // Without the remaining allowance, the period total the cap resets on.
  const totals = { ...live.data, limit_remaining: undefined, usage_daily: 3.75 };
  assert.equal(normalizeUsage('openrouter', { data: totals }, now).windows.find(item => item.name === 'spend-limit').remaining_ratio, 0.75);

  // A cap whose period the key does not account for is not reported at all;
  // a guess here refuses routing to an account that is fine.
  const unknown = normalizeUsage('openrouter', { data: { ...totals, usage_daily: undefined } }, now);
  assert.deepEqual(unknown.windows.map(item => item.name), ['credit'], 'unknown is a missing window, not an invented one');
});

test('an exhausted spend cap stops the route instead of spending on', () => {
  const policy = require('../scripts/ccr/policy.cjs');
  const target = { id: 'openrouter/glm-5.3', provider: 'openrouter', context_window: 200000 };
  const account = { id: 'a', provider: 'openrouter', enabled: true, created_at: 1,
    usage: normalizeUsage('openrouter', { data: { total_credits: 40, total_usage: 40 } }, 1000) };
  assert.deepEqual(policy.blockers(account, target, 1000).map(item => item.reason), ['quota-exhausted']);
  assert.equal(policy.candidates([account], { phase: 2, models: [target] }, {}, 1000).length, 0);
  assert.match(policy.unavailable([account], { phase: 2, models: [target] }, 1000).message, /quota exhausted/);
});

test('a metered account reports money, a subscription reports none', () => {
  const live = { data: { total_credits: 10, total_usage: 7.541665302, usage: 5.071964802,
    usage_daily: 5.071964802, usage_weekly: 5.071964802, usage_monthly: 5.071964802,
    is_free_tier: false, expires_at: null, free_model_daily_requests: { used: 0, limit: 1000, remaining: 1000 } } };
  const { spend } = normalizeUsage('openrouter', live, 1000);
  assert.equal(spend.currency, 'USD');
  assert.equal(spend.used, 7.541665, 'the account balance is what actually stops requests');
  assert.equal(spend.limit, 10);
  assert.equal(spend.remaining, 2.458335);
  assert.equal(spend.key_used, 5.071965, 'this key spent less than the account it belongs to');
  assert.deepEqual(spend.free_requests, { used: 0, limit: 1000, remaining: 1000 });
  assert.equal(spend.expires_at, undefined, 'a key with no expiry reports none');
  assert.equal(spend.free_tier, undefined);
  // A key that does expire says when, because that stops it as surely as an empty balance.
  const expiring = normalizeUsage('openrouter', { data: { total_credits: 10, total_usage: 1, expires_at: '2027-01-01T00:00:00Z' } }, 1000);
  assert.equal(expiring.spend.expires_at, Date.parse('2027-01-01T00:00:00Z'));
  assert.equal(normalizeUsage('openrouter', { data: { is_free_tier: true, total_credits: 1, total_usage: 0 } }, 1000).spend.free_tier, true);
  // A subscription is billed by its plan, not its requests.
  assert.equal(normalizeUsage('anthropic', { five_hour: { utilization: 10, resets_at: 2 } }, 1000).spend, undefined);
  // Nothing numeric means nothing to report, rather than an empty money object.
  assert.equal(normalizeUsage('openrouter', { data: {} }, 1000).spend, undefined);
});

test('a spend cap that reports a period becomes a reset time only where UTC is unambiguous', () => {
  const { periodReset } = require('../scripts/ccr/accounts.cjs');
  const now = Date.parse('2026-09-19T21:30:00Z');
  assert.equal(periodReset('hourly', now), '2026-09-19T22:00:00.000Z');
  assert.equal(periodReset('daily', now), '2026-09-20T00:00:00.000Z');
  assert.equal(periodReset('monthly', now), '2026-10-01T00:00:00.000Z');
  // Which day a week rolls over on is the provider's business, not a guess.
  assert.equal(periodReset('weekly', now), null);
  assert.equal(periodReset('', now), null);
  assert.equal(periodReset(null, now), null);
  assert.equal(periodReset('2026-10-01T00:00:00Z', now), '2026-10-01T00:00:00.000Z');
  // A bare number in this position means Unix seconds to the window reader, so
  // the reset must not arrive as milliseconds.
  const usage = normalizeUsage('openrouter', { data: { total_credits: 10, total_usage: 7.54, limit: 15, usage: 5.07, usage_daily: 5.07, limit_reset: 'daily' } }, now);
  const window = usage.windows.find(item => item.name === 'spend-limit');
  assert.equal(new Date(window.resets_at).toISOString(), '2026-09-20T00:00:00.000Z');
  assert.equal(usage.spend.key_limit, 15);
  assert.equal(usage.spend.key_remaining, undefined, 'absent when the provider does not report it');
  assert.equal(usage.spend.key_limit_period, 'daily');
});

test('readings are kept so a window too long to report recent use can be measured', () => {
  const { usageSamples } = require('../scripts/ccr/accounts.cjs');
  const reading = (at, remaining) => ({ observed_at: at, windows: [{ name: 'weekly', remaining_ratio: remaining }] });
  const start = Date.parse('2026-09-20T09:00:00Z');
  let history = usageSamples(undefined, reading(start, 0.9));
  assert.deepEqual(history, [{ at: start, windows: { weekly: 0.9 } }]);
  // A refresh a minute later is the same half hour, and the registry is not a
  // time series; the sample already taken stands.
  history = usageSamples(history, reading(start + 60000, 0.88));
  assert.deepEqual(history, [{ at: start, windows: { weekly: 0.9 } }]);
  history = usageSamples(history, reading(start + 2400000, 0.85));
  assert.deepEqual(history.map(sample => sample.at), [start, start + 2400000]);
  // Beyond a day there is nothing left to measure, so the sample goes.
  history = usageSamples(history, reading(start + 90000000, 0.5));
  assert.deepEqual(history.map(sample => sample.at), [start + 2400000, start + 90000000]);
  // A reading with nothing in it keeps what was already watched.
  assert.deepEqual(usageSamples(history, { observed_at: start + 90060000, windows: [] }), history);
  assert.deepEqual(usageSamples(history, undefined), history);
  assert.deepEqual(usageSamples('not a history', reading(start, 0.9)), [{ at: start, windows: { weekly: 0.9 } }]);
});

test('a window records how long it counts for, not only when it comes back', () => {
  const { periodLength } = require('../scripts/ccr/accounts.cjs');
  const now = Date.parse('2026-09-19T21:30:00Z');
  assert.equal(periodLength('hourly', now), 3600000);
  assert.equal(periodLength('daily', now), 86400000);
  // September is 30 days, not an assumed 31 or 30.44.
  assert.equal(periodLength('monthly', now), 30 * 86400000);
  assert.equal(periodLength('2026-10-01T00:00:00Z', now), undefined, 'a date says when, not how long');
  assert.equal(periodLength('weekly', now), undefined);

  const subscription = normalizeUsage('anthropic', { five_hour: { utilization: 10, resets_at: '2026-09-19T23:00:00Z' },
    seven_day: { utilization: 20, resets_at: '2026-09-24T00:00:00Z' } }, now);
  assert.deepEqual(subscription.windows.map(item => [item.name, item.period_ms]),
    [['5h', 5 * 3600000], ['weekly', 7 * 86400000]]);
  // The provider states the period in seconds, so an unfamiliar one still has
  // a length even though its name falls back.
  const codex = normalizeUsage('openai', { rate_limit: { primary_window: { used_percent: 25, limit_window_seconds: 10800 } } });
  assert.deepEqual(codex.windows.map(item => [item.name, item.period_ms]), [['session', 10800000]]);

  const metered = normalizeUsage('openrouter', { data: { total_credits: 10, total_usage: 2, limit: 15, usage: 5, usage_daily: 5, limit_reset: 'daily' } }, now);
  assert.deepEqual(metered.windows.map(item => [item.name, item.period_ms]), [['credit', undefined], ['spend-limit', 86400000]],
    'a balance is not a period');
});
