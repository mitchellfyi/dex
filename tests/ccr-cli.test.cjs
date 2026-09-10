'use strict';
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const state = require('../scripts/ccr/state.cjs');
const cli = require('../scripts/ccr/cli.cjs');
const onboarding = require('../scripts/ccr/onboarding.cjs');
const { CredentialStore } = require('../scripts/ccr/accounts.cjs');
const { launchArguments, launchEnvironment } = require('../scripts/ccr/launch.cjs');
let directory;
beforeEach(() => { directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-cli-')); process.env.DEX_ROUTER_HOME = directory; });
afterEach(() => fs.rmSync(directory, { recursive: true, force: true }));

test('CLI rejects missing and unknown option values', () => {
  assert.throws(() => cli.parse(['--session']), /requires/);
  assert.throws(() => cli.parse(['--api-key', 'secret']), /Unknown/);
  assert.deepEqual(cli.parse(['configure', 'openai/test', '--fallback', 'anthropic/test', '--phase', 'review']).fallback, ['anthropic/test']);
});
test('empty account and status commands work without starting CCR', async () => {
  const status = await cli.routerCommand('status', {});
  assert.equal(status.enabled, false); assert.equal(status.health, 'stopped'); assert.equal(status.installed, false);
  assert.deepEqual(cli.accountRows([]), []);
});
test('model registration and phase configuration preserve explicit fallbacks', async () => {
  const options = { context: '128000', tools: true, fallback: [] };
  await cli.modelCommand('add', ['anthropic/claude-test'], options);
  await cli.modelCommand('add', ['openai/codex-test'], options);
  await cli.routeCommand('configure', ['anthropic/claude-test'], { fallback: [] });
  await cli.routeCommand('configure', ['openai/codex-test'], { phase: 'implement', fallback: ['anthropic/claude-test'], effort: 'high' });
  assert.equal(Object.keys(state.config().phases).length, 7);
  assert.equal(state.config().phases[2].model, 'openai/codex-test');
  assert.equal(state.config().phases[3].model, 'anthropic/claude-test');
  await assert.rejects(cli.routeCommand('configure', ['unknown/model'], { fallback: [] }), /model/);
  await assert.rejects(cli.modelCommand('add', ['openai/test'], { context: '-1' }), /context/);
});
test('account controls preserve identity and delete selected credentials only', async () => {
  state.saveAccounts([{ id: 'one', name: 'Personal', provider: 'openai', enabled: true }, { id: 'two', name: 'Work', provider: 'openai', enabled: true }]);
  const store = new CredentialStore('linux'); store.set('one', { refresh_token: 'synthetic-one' }); store.set('two', { refresh_token: 'synthetic-two' });
  await onboarding.changeAccount('disable', 'Personal', null, store);
  assert.equal(state.getAccount('Personal').enabled, false);
  await assert.rejects(onboarding.changeAccount('rename', 'one', 'Work', store), /already/);
  await onboarding.changeAccount('rename', 'one', 'Personal two', store);
  await onboarding.changeAccount('remove', 'Personal two', null, store);
  assert.equal(store.get('one'), null); assert.equal(store.get('two').refresh_token, 'synthetic-two');
});
test('model catalogue preserves unknown context provenance and modality', () => {
  const models = onboarding.catalogue('openai', { models: [{ slug: 'test', context_window: 128000, input_modalities: ['text', 'image'] }, { slug: 'unknown' }] });
  assert.equal(models[0].capabilities.images, true); assert.equal(models[0].context_source, 'provider');
  assert.equal(models[1].context_source, 'conservative-default');
});
test('account identity and names cannot inject terminal or shell commands', async () => {
  assert.throws(() => onboarding.accountName('bad\x1b[2J'), /name/);
  assert.throws(() => onboarding.accountName('$(whoami)'), /name/);
  assert.equal(cli.clean('hello\x1b[31m'), 'hello [31m');
  await assert.rejects(onboarding.identity('openai', { access_token: 'key' }), /subscription/);
});
test('launch uses private transport env and keeps native credentials out of argv', () => {
  const parsed = launchArguments(['--model', 'openai/test', '--fallback-model', 'opus', '-p', 'task']);
  assert.equal(parsed.requested, 'openai/test'); assert.equal(parsed.args.filter(arg => arg === '--model').length, 1);
  assert.ok(parsed.args.includes('bypassPermissions'));
  const env = launchEnvironment({ gateway: 'http://127.0.0.1:1234' }, 'synthetic-session-token', { id: 'run1', context_limit: 128000 }, { ANTHROPIC_API_KEY: 'bad', OPENAI_API_KEY: 'bad', CCR_WEB_AUTH_TOKEN: 'bad', PATH: '/bin' });
  assert.equal(env.ANTHROPIC_API_KEY, undefined); assert.equal(env.CCR_WEB_AUTH_TOKEN, undefined);
  assert.equal(env.ANTHROPIC_AUTH_TOKEN, 'synthetic-session-token'); assert.equal(env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, '128000');
  assert.equal(parsed.args.includes('synthetic-session-token'), false);
});
test('native login uses only official subscription commands', () => {
  assert.deepEqual(onboarding.loginCommand('anthropic'), ['claude', ['auth', 'login', '--claudeai']]);
  assert.equal(onboarding.loginCommand('openai', true)[1].at(-1), '--device-auth');
  assert.throws(() => onboarding.loginCommand('anthropic', true), /browser/);
});
test('OpenAI onboarding confirms identity, rejects duplicates and cancels without replacing credentials', async () => {
  const store = new CredentialStore('linux');
  const claims = `header.${Buffer.from(JSON.stringify({ sub: 'person1', email: 'test@example.test' })).toString('base64url')}.signature`;
  const login = async (_provider, home) => state.write(path.join(home, 'auth.json'), { tokens: { account_id: 'org1', id_token: claims, access_token: 'synthetic', refresh_token: 'synthetic-refresh' } });
  const added = await onboarding.register({ provider: 'openai', name: 'Personal', store, login, confirm: async label => label === 'test@example.test' });
  assert.equal(state.accounts().length, 1); assert.equal(store.get(added.id).refresh_token, 'synthetic-refresh');
  await assert.rejects(onboarding.register({ provider: 'openai', name: 'Duplicate', store, login }), /already registered/);
  await assert.rejects(onboarding.register({ provider: 'openai', name: 'Personal', reauth: added.id, store, login, confirm: async () => false }), /cancelled/);
  assert.equal(state.accounts().length, 1); assert.equal(store.get(added.id).refresh_token, 'synthetic-refresh');
  assert.deepEqual(fs.readdirSync(path.join(directory, 'logins')), []);
});
test('auth-only Codex wrapper reaches native login without requiring an existing login', () => {
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'codex'), '#!/bin/sh\nprintf "%s\\n" "$@"\n', { mode: 0o700 });
  const env = { ...process.env, DEX_DIR: path.resolve('.'), DEX_ROUTER_AUTH_HOME: directory, CODEX_HOME: directory, PATH: `${bin}:${process.env.PATH}` };
  const result = spawnSync('bash', ['bin/dxcodex.sh', 'auth-login', '--device-auth'], { encoding: 'utf8', env });
  assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /cli_auth_credentials_store="file"\nlogin\n--device-auth/);
  const rejected = spawnSync('bash', ['bin/dxcodex.sh', 'auth-login', '--with-api-key'], { encoding: 'utf8', env });
  assert.notEqual(rejected.status, 0);
});
test('native credential helper dispatches stdin operations without positional arguments', () => {
  const result = spawnSync('python3', ['scripts/ccr/native.py'], { input: JSON.stringify({ operation: 'read', service: 'forbidden', account: 'test' }), encoding: 'utf8' });
  assert.notEqual(result.status, 0); assert.match(result.stderr, /ValueError/); assert.doesNotMatch(result.stderr, /IndexError/);
});
test('CLI errors and machine output work from a separate process', () => {
  const run = args => spawnSync(process.execPath, [path.resolve('scripts/ccr/cli.cjs'), ...args], { encoding: 'utf8', env: { ...process.env, DEX_ROUTER_HOME: directory } });
  assert.deepEqual(JSON.parse(run(['accounts', '--json']).stdout).accounts, []);
  assert.notEqual(run(['account', 'show', 'missing']).status, 0);
  assert.match(run(['account', 'show', 'missing']).stderr, /Account not found/);
  assert.notEqual(run(['route', 'use', 'openai/test']).status, 0);
});
