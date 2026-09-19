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
  assert.equal(providerKind('openrouter'), 'api-key');
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

test('a spend cap exhausts like a quota and an uncapped key reports no window', () => {
  const capped = normalizeUsage('openrouter', { data: { limit: 40, usage: 40 } }, 1000);
  assert.deepEqual(capped.windows, [{ name: 'credit', remaining_ratio: 0, resets_at: null }]);
  const partial = normalizeUsage('openrouter', { data: { limit: 40, usage: 10 } }, 1000);
  assert.equal(partial.windows[0].remaining_ratio, 0.75);
  assert.deepEqual(normalizeUsage('openrouter', { data: { limit: null, usage: 3 } }, 1000).windows, [],
    'no cap means no window to exhaust, not a window at zero');
});

test('an exhausted spend cap stops the route instead of spending on', () => {
  const policy = require('../scripts/ccr/policy.cjs');
  const target = { id: 'openrouter/glm-5.3', provider: 'openrouter', context_window: 200000 };
  const account = { id: 'a', provider: 'openrouter', enabled: true, created_at: 1,
    usage: normalizeUsage('openrouter', { data: { limit: 40, usage: 40 } }, 1000) };
  assert.deepEqual(policy.blockers(account, target, 1000).map(item => item.reason), ['quota-exhausted']);
  assert.equal(policy.candidates([account], { phase: 2, models: [target] }, {}, 1000).length, 0);
  assert.match(policy.unavailable([account], { phase: 2, models: [target] }, 1000).message, /quota exhausted/);
});
