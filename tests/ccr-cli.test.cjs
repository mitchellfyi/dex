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
const { launchArguments, launchEnvironment, launch } = require('../scripts/ccr/launch.cjs');
const adapter = require('../scripts/ccr/adapter.cjs');
const ipc = require('../scripts/ccr/ipc.cjs');
const policy = require('../scripts/ccr/policy.cjs');
const { table } = require('../scripts/ccr/output.cjs');
let directory;
beforeEach(() => { directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-cli-')); process.env.DEX_ROUTER_HOME = directory; });
afterEach(() => fs.rmSync(directory, { recursive: true, force: true }));

test('prompt-only launch treats text after the option terminator literally', () => {
  for (const prompt of ['--model', '--model=unrelated', '--resume', '--fork-session']) {
    const result = launchArguments(['--model', 'anthropic/test', '--', prompt]);
    assert.equal(result.requested, 'anthropic/test');
    assert.equal(result.resume, false);
    assert.deepEqual(result.args.slice(-2), ['--', prompt]);
  }
  assert.equal(launchArguments(['--resume', 'conversation', '--', '--fork-session']).resume, true);
});

test('standalone sessions launch without phase files while workflows follow their phase', async t => {
  const saved = Object.fromEntries(['PATH', 'DEX_SESSION_ID', 'DEX_SESSION_ONLY', 'DX_STATE_DIR'].map(key => [key, process.env[key]]));
  t.after(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  Object.assign(process.env, { PATH: `${bin}:${process.env.PATH}`, DEX_SESSION_ID: 'prompt-test', DEX_SESSION_ONLY: '1', DX_STATE_DIR: directory });
  const config = { models: [{ id: 'anthropic/test', context_window: 64000 }], phases: {}, default_model: 'anthropic/test' };
  const phases = [];
  t.mock.method(adapter, 'start', async () => ({ gateway: 'http://127.0.0.1:1234' }));
  t.mock.method(ipc, 'call', async (method, fields) => {
    if (method !== 'register') return {};
    phases.push(policy.route(config, fields).phase);
    return { id: fields.id, context_limit: 64000 };
  });
  assert.equal(await launch(['--', 'example prompt']), 0);
  process.env.DEX_SESSION_ID = 'workflow-test';
  process.env.DEX_SESSION_ONLY = '0';
  fs.writeFileSync(path.join(directory, 'workflow-test.phase'), '3\n', { mode: 0o600 });
  assert.equal(await launch(['--', 'continue the workflow']), 0);
  assert.deepEqual(phases, [0, 3]);
});

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
test('dashboard distinguishes current account exhaustion from stale and model-only quotas', () => {
  const account = { name: 'Main', provider: 'anthropic', enabled: true, usage: { observed_at: Date.now(), windows: [{ name: 'weekly', remaining_ratio: 0 }] } };
  const output = () => cli.accountRows([account]).flat().join(' ');
  assert.match(output(), /quota exhausted/);
  account.usage.windows[0].model_pool = 'opus';
  assert.doesNotMatch(output(), /quota exhausted/);
  delete account.usage.windows[0].model_pool;
  account.usage.observed_at -= 180000;
  assert.doesNotMatch(output(), /quota exhausted/);
  assert.match(output(), /stale/);
});
test('account status names limited models and reports short cooldowns in seconds', () => {
  const now = Date.now();
  const account = { name: 'Main', provider: 'anthropic', enabled: true, model_cooldowns: { 'anthropic/claude-fable-5-1': now + 12000, 'anthropic/claude-opus-5': now - 1000 } };
  assert.equal(cli.accountRows([account], now)[0][2], 'claude-fable-5-1 rate limited (12s)');
  account.cooldown_until = now + 8000; account.cooldown_reason = 'temporary';
  assert.equal(cli.accountRows([account], now)[0][2], 'temporary provider error (8s)');
  assert.equal(cli.accountRows([account], now + 13000)[0][2], 'ready');
});
test('account rows compare quota windows side by side and distinguish due and unknown resets', () => {
  const now = Date.now();
  const account = { name: 'Main', provider: 'anthropic', enabled: true, usage: { observed_at: now, windows: [
    { name: 'weekly', remaining_ratio: 0.4, resets_at: now + (3 * 24 + 4) * 3600000 },
    { name: '5h', remaining_ratio: 0.72, resets_at: now + (2 * 60 + 14) * 60000 },
    { name: 'weekly-opus', model_pool: 'opus', remaining_ratio: 0, resets_at: now - 1 }
  ] } };
  const weeklyOnly = { name: 'Personal', provider: 'openai', enabled: true, usage: { observed_at: now, windows: [
    { name: 'weekly', remaining_ratio: .91, resets_at: null }
  ] } };
  const rows = cli.accountRows([account, weeklyOnly, { name: 'Backup', provider: 'openai', enabled: false }], now);
  assert.deepEqual(rows, [
    ['Main', 'anthropic', 'ready', '72%', '2h 14m', '40%', '3d 4h', '0%', 'due'],
    ['Personal', 'openai', 'ready', '-', '-', '91%', 'unknown', '-', '-'],
    ['Backup', 'openai', 'disabled', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown']
  ]);
  account.usage_error = 'Refresh failed';
  assert.match(cli.accountRows([account], now)[0][3], /stale/);
  account.status = 'reauth-required';
  account.cooldown_until = now + 60000;
  assert.equal(cli.accountRows([account], now)[0][2], 'reauth-required');
});
test('table rendering does not alter JSON output or saved account and model data', () => {
  const items = [{ id: 'one', name: 'Main', identity: 'test@example.test', provider: 'openai', enabled: true }];
  const config = { version: 1, enabled: false, models: [{ id: 'openai/test', context_window: 128000, capabilities: { tools: true, images: false } }], phases: {}, default_model: 'openai/test' };
  state.saveAccounts(items); state.write(state.stateFile('config'), config);
  const run = args => {
    const result = spawnSync(process.execPath, ['scripts/ccr/cli.cjs', ...args], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  };
  assert.match(run(['accounts']), /Account +Provider +Status +5h left +Reset in +Weekly left +Reset in/);
  assert.match(run(['accounts']), /Tip: use dx accounts --live for updates\./);
  assert.match(run(['account', 'show', 'Main']), /test@example.test/);
  assert.match(run(['model', 'list']), /128,000/);
  assert.match(run(['route', 'policy']), /Fallbacks \(in order\)/);
  assert.match(run(['router', 'status']), /Active sessions/);
  assert.deepEqual(JSON.parse(run(['accounts', '--json'])), { version: 1, accounts: items });
  assert.deepEqual(JSON.parse(run(['account', 'show', 'Main', '--json'])), items[0]);
  assert.deepEqual(JSON.parse(run(['model', 'list', '--json'])), config.models);
  assert.deepEqual(JSON.parse(run(['route', 'policy', '--json'])), config);
  assert.deepEqual(state.accounts(), items); assert.deepEqual(state.config(), config);
  const narrow = table(['Account', 'Status', 'Quota window'], [['Long account name', 'reauth-required', 'unknown']], { width: 24 });
  assert.ok(narrow.split('\n').every(line => line.length <= 24));
  assert.match(narrow, /Status: reauth-required/);
});
test('live and watch are aliases that require an account table and an interactive terminal', async () => {
  assert.deepEqual(cli.parse(['--live']), cli.parse(['--watch']));
  for (const flag of ['--live', '--watch']) {
    for (const args of [['accounts', flag, '--json'], ['model', 'list', flag]]) {
      const result = spawnSync(process.execPath, ['scripts/ccr/cli.cjs', ...args], { encoding: 'utf8' });
      assert.notEqual(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /--live\/--watch/);
    }
    const result = spawnSync(process.execPath, ['scripts/ccr/cli.cjs', 'accounts', flag], { encoding: 'utf8' });
    assert.notEqual(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /interactive terminal/);
  }
});
test('live updates replace the table, keep refresh failures visible and restore the terminal on errors', async t => {
  const descriptor = Object.getOwnPropertyDescriptor(process.stdout, 'isTTY');
  const rowsDescriptor = Object.getOwnPropertyDescriptor(process.stdout, 'rows');
  Object.defineProperty(process.stdout, 'isTTY', { value: true, configurable: true });
  Object.defineProperty(process.stdout, 'rows', { value: 8, configurable: true });
  t.after(() => {
    if (descriptor) Object.defineProperty(process.stdout, 'isTTY', descriptor); else delete process.stdout.isTTY;
    if (rowsDescriptor) Object.defineProperty(process.stdout, 'rows', rowsDescriptor); else delete process.stdout.rows;
  });
  const writes = [], intervals = [];
  const listeners = ['SIGINT', 'SIGTERM', 'exit'].map(signal => process.listenerCount(signal));
  t.mock.method(process.stdout, 'write', value => { writes.push(value); return true; });
  t.mock.method(globalThis, 'setTimeout', (callback, delay) => { intervals.push(delay); callback(); });
  const account = { id: 'main', name: 'Main', enabled: true, provider: 'openai', usage: { observed_at: Date.now(), windows: [{ name: '5h', remaining_ratio: .8 }] } };
  const stopped = new Error('End synthetic watch');
  let reads = 0, refreshes = 0;
  t.mock.method(state, 'accounts', () => { if (++reads === 5) throw stopped; return [account]; });
  t.mock.method(adapter, 'health', async () => reads < 4);
  t.mock.method(ipc, 'call', async method => {
    assert.equal(method, 'usage');
    if (++refreshes === 3) throw new Error('Synthetic refresh failure');
    return [{ ...account, usage: { ...account.usage, windows: [{ name: '5h', remaining_ratio: refreshes === 1 ? .7 : .6 }] } }];
  });
  await assert.rejects(cli.main(['accounts', '--live']), error => error === stopped);
  const frames = writes.filter(value => value.startsWith('\x1b[H'));
  assert.equal(writes[0], '\x1b[?1049h\x1b[?25l');
  assert.equal(writes.at(-1), '\x1b[?25h\x1b[?1049l');
  assert.equal(frames.length, 5);
  assert.ok(frames.every(frame => frame.endsWith('\x1b[J')));
  assert.match(frames[1], /70%/); assert.match(frames[2], /60%/); assert.doesNotMatch(frames[2], /70%/);
  assert.match(frames[3], /Quota refresh unavailable/);
  assert.match(frames[3], /use dx accounts to see all rows/);
  assert.match(frames[4], /CCR is stopped; showing cached readings/);
  assert.match(frames[4], /Ctrl\+C to exit/);
  assert.deepEqual(intervals, [30000, 30000, 30000, 30000]);
  assert.deepEqual(['SIGINT', 'SIGTERM', 'exit'].map(signal => process.listenerCount(signal)), listeners);
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
test('explicit discovery refreshes account eligibility as well as the shared catalogue', async t => {
  state.saveAccounts([{ id: 'one', name: 'Main', provider: 'openai', enabled: true, model_ids: ['openai/old'] }]);
  const models = onboarding.catalogue('openai', { models: [{ slug: 'new', context_window: 128000 }] });
  t.mock.method(onboarding, 'discover', async () => models);
  await cli.modelCommand('discover', ['Main'], {});
  assert.deepEqual(state.getAccount('Main').model_ids, ['openai/new']);
  assert.equal(state.config().models[0].id, 'openai/new');
});
test('OpenAI discovery uses the installed Codex version instead of hiding newer models', async () => {
  const broker = { access: async () => ({ access_token: 'synthetic' }) };
  const fetchCatalogue = async endpoint => {
    const version = new URL(endpoint).searchParams.get('client_version');
    return Response.json({ models: [{ slug: version === '0.153.4' ? 'current-model' : 'legacy-model' }] });
  };
  const models = await onboarding.discover({ provider: 'openai' }, broker, fetchCatalogue, () => '0.153.4');
  assert.equal(models[0].id, 'openai/current-model');
  await onboarding.discover({ provider: 'anthropic' }, broker, async () => Response.json({ data: [] }), () => { throw new Error('Codex is not needed for Anthropic'); });
  assert.equal(onboarding.codexVersion(() => ({ status: 0, stdout: 'codex-cli 0.153.4\n' })), '0.153.4');
  for (const result of [{ status: 1 }, { status: 0, stdout: 'not Codex' }, { status: 0, stdout: 'codex-cli 0.153.4&unexpected=value' }]) {
    assert.throws(() => onboarding.codexVersion(() => result), /official Codex CLI/);
  }
});
test('temporary native files are removed even when Keychain cleanup fails', () => {
  const login = path.join(directory, 'login'); fs.mkdirSync(login);
  fs.writeFileSync(path.join(login, 'native.json'), 'synthetic');
  assert.throws(() => onboarding.cleanupNative('anthropic', login, null, () => { throw new Error('Keychain unavailable'); }, 'darwin'), /Keychain unavailable/);
  assert.equal(fs.existsSync(login), false);
});
test('native login progress stays on stderr for machine-readable command output', () => {
  const bin = path.join(directory, 'login-bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\nprintf "synthetic login progress\\n"\n', { mode: 0o700 });
  const script = `require(${JSON.stringify(path.resolve('scripts/ccr/onboarding.cjs'))}).nativeLogin('anthropic', ${JSON.stringify(directory)}, false)`;
  const result = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
  assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, ''); assert.match(result.stderr, /synthetic login progress/);
});
test('JSON commands reject missing interactive choices before printing prompts', () => {
  for (const args of [['account', 'add', '--json'], ['account', 'remove', 'Main', '--json'], ['router', 'setup', '--json']]) {
    const result = spawnSync(process.execPath, ['scripts/ccr/cli.cjs', ...args], { encoding: 'utf8' });
    assert.notEqual(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /--json/);
  }
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
  assert.equal(parsed.resume, false);
  assert.equal(launchArguments(['--resume', 'conversation-one']).resume, true);
  assert.equal(launchArguments(['--continue']).resume, true);
  assert.equal(launchArguments(['--resume', 'conversation-one', '--fork-session']).resume, false);
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
test('the CCR provider resolves as Claude and captures the native resume handle', () => {
  const env = { ...process.env, DEX_DIR: path.resolve('.'), DX_STATE_DIR: path.join(directory, 'phases'), DX_LOOP_DIR: path.join(directory, 'loops'), DEX_SESSION_ID: 'ccr-capture', DX_PROVIDER_ENGINE: 'ccr', DX_PROVIDER_PROFILE: 'ccr-subscription', DX_AGENT_OVERRIDE: '' };
  fs.mkdirSync(env.DX_STATE_DIR, { mode: 0o700 }); fs.mkdirSync(env.DX_LOOP_DIR, { mode: 0o700 });
  const profile = spawnSync('bash', ['-c', 'source "$DEX_DIR/lib/common.sh"; dx_provider_apply; printf "%s/%s/%s" "$DX_PROVIDER_ENGINE" "$DX_PROVIDER_AGENT" "$DX_CLAUDE_MODEL"'], { encoding: 'utf8', env });
  assert.equal(profile.status, 0, profile.stderr); assert.equal(profile.stdout, 'ccr/claude/dex/active');
  const capture = spawnSync('bash', ['hooks/capture-provider-session.sh'], { encoding: 'utf8', env, input: JSON.stringify({ hook_event_name: 'SessionStart', session_id: 'conversation-native-123' }) });
  assert.equal(capture.status, 0, capture.stderr);
  assert.equal(fs.readFileSync(path.join(env.DX_STATE_DIR, 'ccr-capture.claude-session'), 'utf8').trim(), 'conversation-native-123');
});
test('routing help and direct setup help do not require Node', () => {
  const bin = path.join(directory, 'no-node'); fs.mkdirSync(bin);
  const marker = path.join(directory, 'node-called'); fs.writeFileSync(path.join(bin, 'node'), `#!/bin/sh\ntouch '${marker}'\nexit 99\n`, { mode: 0o700 });
  const env = { ...process.env, DEX_DIR: path.resolve('.'), PATH: `${bin}:${process.env.PATH}` };
  for (const script of ['bin/router.sh', 'bin/setup.sh']) {
    const result = spawnSync('bash', [script, '--help'], { encoding: 'utf8', env }); assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /Usage:/);
    if (script === 'bin/router.sh') assert.match(result.stdout, /dx accounts --live \(or --watch\) to update the table in place every 30 seconds/);
  }
  assert.equal(fs.existsSync(marker), false);
});
test('cached status line reports usage without reading provider credentials', () => {
  state.saveAccounts([{ id: 'one', name: 'Main', usage: { observed_at: Date.now(), windows: [{ name: '5h', remaining_ratio: 0.4 }] } }]);
  state.write(state.sessionFile('current'), { current_account: 'one', current_model: 'openai/test' });
  const result = spawnSync('python3', ['scripts/router-status.py'], { encoding: 'utf8', env: { ...process.env, DX_ROUTER_SESSION_ID: 'current' } });
  assert.equal(result.status, 0); assert.match(result.stdout, /openai\/test \/ Main \/ 5h 40%/);
});
test('CLI errors and machine output work from a separate process', () => {
  const run = args => spawnSync(process.execPath, [path.resolve('scripts/ccr/cli.cjs'), ...args], { encoding: 'utf8', env: { ...process.env, DEX_ROUTER_HOME: directory } });
  assert.deepEqual(JSON.parse(run(['accounts', '--json']).stdout).accounts, []);
  assert.notEqual(run(['account', 'show', 'missing']).status, 0);
  assert.match(run(['account', 'show', 'missing']).stderr, /Account not found/);
  assert.notEqual(run(['route', 'use', 'openai/test']).status, 0);
});
