'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const state = require('../scripts/ccr/state.cjs');
const { CredentialStore, AccountBroker, normalizeTokens, nativeEnv, normalizeUsage } = require('../scripts/ccr/accounts.cjs');

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
