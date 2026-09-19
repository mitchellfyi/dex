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
const { launchArguments, launchSettings, launchEnvironment, gatewayMonitor, launch } = require('../scripts/ccr/launch.cjs');
const { claudePicker } = require('../scripts/ccr/claude-picker.cjs');
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

test('routed picker has one automatic entry and explicit models remain labeled as routed', () => {
  const config = { default_model: 'anthropic/new', phases: { 0: { model: 'anthropic/new', fallbacks: ['anthropic/previous', 'openai/new'] }, 2: { model: 'anthropic/new' } },
    models: ['anthropic/new', 'anthropic/previous', 'openai/new'].map(id => ({ id })) };
  const picker = claudePicker(config);
  assert.equal(picker.replaceBuiltInOptions, true);
  assert.deepEqual(picker.options.map(option => option.model), ['dex/active[1m]', 'anthropic/new[1m]', 'anthropic/previous[1m]', 'openai/new[1m]']);
  assert.equal(picker.options[0].label, 'CCR subscription');
  assert.ok(picker.options.slice(1).every(option => option.label.endsWith('(via CCR)')));
  const supplied = { statusLine: { type: 'command', command: 'status-command' }, crossSessionInbound: 'accept', permissions: { allow: ['Read'] } };
  const file = path.join(directory, 'settings.json'); fs.writeFileSync(file, JSON.stringify(supplied));
  for (const value of [JSON.stringify(supplied), file]) {
    assert.deepEqual(launchSettings(value, config), { modelPicker: picker, ...supplied });
  }
  assert.deepEqual(JSON.parse(fs.readFileSync(file)), supplied);
  const personal = { options: [{ model: 'anthropic/new', label: 'Personal label' }] };
  assert.deepEqual(launchSettings(JSON.stringify({ modelPicker: personal }), config).modelPicker, personal);
  for (const value of ['missing.json', '{broken', 'null', '[]']) assert.throws(() => launchSettings(value, config), /settings/);
  const parsed = launchArguments(['--settings', file, '--settings={"effortLevel":"high"}', '--', '--settings=prompt-text']);
  assert.equal(parsed.settings, '{"effortLevel":"high"}');
  assert.deepEqual(parsed.args.slice(-2), ['--', '--settings=prompt-text']);
  assert.equal(parsed.args.some(arg => arg === file), false);
});

test('standalone sessions launch without phase files while workflows follow their phase', async t => {
  const saved = Object.fromEntries(['PATH', 'DEX_SESSION_ID', 'DEX_SESSION_ONLY', 'DEX_POLICY_SESSION_ID', 'DX_STATE_DIR'].map(key => [key, process.env[key]]));
  t.after(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\n[ "$1" = --settings ] && [ -f "$2" ] || exit 12\nexit 0\n', { mode: 0o700 });
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
  // A review-wave pass has its own session ID but no phase file of its own.
  process.env.DEX_SESSION_ID = 'workflow-test-pass-1';
  process.env.DEX_POLICY_SESSION_ID = 'workflow-test';
  assert.equal(await launch(['-p', '--', 'review the change set']), 0);
  fs.writeFileSync(path.join(directory, 'workflow-test.phase'), '7\n', { mode: 0o600 });
  delete process.env.DEX_POLICY_SESSION_ID; process.env.DEX_SESSION_ID = 'workflow-test';
  assert.equal(await launch(['--', 'present the final summary']), 0);
  assert.deepEqual(phases, [0, 3, 3, 7]);
  assert.equal(fs.readdirSync(directory).some(name => name.startsWith('launch-')), false, 'launch settings are removed after the child exits');
});

test('route policy displays inherited Claude and explicit Codex routes without altering configuration', async t => {
  const config = { version: 1, enabled: true, default_model: 'anthropic/test', phases: { 0: { model: 'anthropic/test', fallbacks: ['openai/test'], effort: 'high' } },
    client_routes: { codex: { model: 'openai/test', fallbacks: [], effort: 'xhigh' } },
    models: ['anthropic/test', 'openai/test'].map(id => ({ id, context_window: 64000 })) };
  state.write(state.stateFile('config'), config);
  const writes = []; t.mock.method(process.stdout, 'write', value => { writes.push(value); return true; });
  await cli.main(['route', 'policy']);
  const output = writes.join('');
  assert.match(output, /claude\s+inherited from setup\s+anthropic\/test\s+openai\/test\s+high/);
  assert.match(output, /codex\s+configured\s+openai\/test\s+-\s+xhigh/);
  assert.match(output, /native configuration \(CCR off\)/);
  assert.deepEqual(state.config(), config);
});

test('route policy remains readable before router setup', async t => {
  const writes = []; t.mock.method(process.stdout, 'write', value => { writes.push(value); return true; });
  await cli.main(['route', 'policy']);
  assert.match(writes.join(''), /claude\s+inherited from setup\s+not selected/);
  assert.match(writes.join(''), /codex\s+inherited from setup\s+not selected/);
});

test('public router setup and enable select one global CCR default only after activation succeeds', () => {
  const root = path.resolve(__dirname, '..');
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'node'), '#!/bin/sh\nif [ "$1" = -e ]; then exit 0; fi\nif [ "${FAIL_ACTIVATION:-}" = 1 ]; then exit 7; fi\nprintf \'"activated"\\n\'\n', { mode: 0o700 });
  const env = { ...process.env, HOME: directory, DEX_DIR: root, PATH: `${bin}:${process.env.PATH}` };
  const file = path.join(directory, '.dex/providers.json');
  const original = { default: 'codex-subscription', profiles: { personal: { engine: 'claude', auth: 'subscription', model: 'opus' } } };
  const run = (action, extra = {}) => spawnSync('bash', [path.join(root, 'bin/router.sh'), 'router', action, '--json'], { cwd: directory, env: { ...env, ...extra }, encoding: 'utf8' });
  for (const action of ['setup', 'enable']) {
    state.write(file, original);
    const failed = run(action, { FAIL_ACTIVATION: '1' });
    assert.equal(failed.status, 7, failed.stderr);
    assert.deepEqual(state.read(file), original);
    const succeeded = run(action);
    assert.equal(succeeded.status, 0, succeeded.stderr);
    assert.equal(JSON.parse(succeeded.stdout), 'activated', 'profile messages stay out of JSON stdout');
    assert.deepEqual(state.read(file), { ...original, default: 'ccr-subscription' });
    assert.match(succeeded.stderr, /global provider profile to ccr-subscription/);
  }
});

test('CLI rejects missing and unknown option values', () => {
  assert.throws(() => cli.parse(['--session']), /requires/);
  assert.throws(() => cli.parse(['--api-key', 'secret']), /Unknown/);
  const parsed = cli.parse(['configure', 'openai/test', '--fallback', 'anthropic/test', '--client', 'codex']);
  assert.deepEqual(parsed.fallback, ['anthropic/test']); assert.equal(parsed.client, 'codex');
});
test('gateway recovery logs its attempts without writing into the native terminal', async t => {
  const writes = [], probes = [];
  t.mock.method(process.stderr, 'write', value => { writes.push(value); return true; });
  t.mock.method(adapter, 'health', async (...args) => { probes.push(args); return null; });
  let attempts = 0;
  t.mock.method(adapter, 'start', async options => {
    assert.deepEqual(options, { recovery: true });
    if (++attempts === 2) throw new Error('Synthetic recovery failure');
    return {};
  });
  const monitor = gatewayMonitor({ id: 'native-terminal' });
  for (let count = 0; count < 9; count++) await monitor.check();
  monitor.stop();
  assert.equal(attempts, 2);
  assert.equal(probes.filter(([, timeout]) => timeout === 10000).length, 2);
  assert.deepEqual(writes, []);
  assert.equal(monitor.failed, true);
  const events = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(events.map(event => event.type), ['router.recovery_started', 'router.recovery_succeeded', 'router.recovery_started', 'router.recovery_failed']);
  assert.deepEqual(events.map(event => event.data.attempt), [1, 1, 2, 2]);
});
test('a slow but responsive gateway does not trigger recovery', async t => {
  const probes = [];
  t.mock.method(adapter, 'health', async (...args) => { probes.push(args); return args[1] === 10000 ? { pid: process.pid } : null; });
  const start = t.mock.method(adapter, 'start', async () => {});
  const monitor = gatewayMonitor({ id: 'slow-gateway' });
  for (let count = 0; count < 6; count++) await monitor.check();
  monitor.stop();
  assert.equal(start.mock.callCount(), 0);
  assert.equal(probes.filter(([, timeout]) => timeout === 10000).length, 2);
  assert.equal(fs.existsSync(path.join(directory, 'events.jsonl')), false);
});
test('ending a client cancels pending recovery and concurrent checks do not overlap', async t => {
  let release, probes = 0;
  t.mock.method(adapter, 'health', async (_deep, timeout) => {
    probes++;
    return timeout === 10000 ? new Promise(resolve => { release = resolve; }) : null;
  });
  const start = t.mock.method(adapter, 'start', async () => {});
  const monitor = gatewayMonitor({ id: 'ended-client' });
  await monitor.check(); await monitor.check();
  const pending = monitor.check();
  await Promise.resolve();
  assert.equal(typeof release, 'function');
  await monitor.check(); assert.equal(probes, 4);
  monitor.stop(); release(null); await pending;
  assert.equal(start.mock.callCount(), 0);
});
test('router status requests a detailed session count explicitly', async t => {
  t.mock.method(adapter, 'health', async () => ({ pid: process.pid }));
  t.mock.method(ipc, 'call', async (method, params) => {
    assert.equal(method, 'health'); assert.deepEqual(params, { sessions: true });
    return { active_sessions: 3 };
  });
  assert.equal((await cli.routerCommand('status', {})).active_sessions, 3);
  assert.equal((await cli.routerCommand('doctor', {})).native_routing, false);
  state.write(state.stateFile('config'), { ...state.config(), native: { enabled: true } });
  assert.equal((await cli.routerCommand('doctor', {})).native_routing, true);
});
test('deep health matches the live gateway identity without launching process scans', async t => {
  const settings = { pid: 2147483647, owner_identity: 'synthetic-owner', management: 'http://127.0.0.1:1', management_key: 'synthetic-key' };
  let identity = settings.owner_identity;
  t.mock.method(state, 'backend', () => settings);
  t.mock.method(ipc, 'call', async (method, params, timeout) => {
    assert.equal(method, 'health'); assert.deepEqual(params, {}); assert.equal(timeout, 10000);
    return { version: 1, extension: 'dex-ccr', pid: settings.pid, owner_identity: identity };
  });
  const fetch = t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({ ok: true, value: { state: 'running' } })));
  assert.equal((await adapter.health(true, 10000)).owner_identity, 'synthetic-owner');
  identity = 'previous-owner';
  assert.equal(await adapter.health(true, 10000), null);
  identity = '';
  assert.equal(await adapter.health(true, 10000), null);
  assert.equal(fetch.mock.callCount(), 1);
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
  assert.equal(cli.accountRows([account], now)[0][4], 'claude-fable-5-1 rate limited (12s)');
  account.model_cooldown_reasons = { 'anthropic/claude-fable-5-1': 'temporary' };
  assert.equal(cli.accountRows([account], now)[0][4], 'claude-fable-5-1 temporary provider error (12s)');
  account.cooldown_until = now + 8000; account.cooldown_reason = 'temporary';
  assert.equal(cli.accountRows([account], now)[0][4], 'temporary provider error (8s)');
  account.cooldown_reason = 'terms-required';
  assert.equal(cli.accountRows([account], now)[0][4], 'accept terms in claude.ai (8s)');
  assert.equal(cli.accountRows([account], now + 13000)[0][4], 'ready');
});
test('account/model rows compare primary and fallback capacity without mixing model quotas', () => {
  const now = Date.now(), primary = 'anthropic/claude-fable-5-1', fallback = 'anthropic/claude-opus-5';
  const config = { default_model: primary, phases: { 0: { model: primary, fallbacks: [fallback] }, 2: { model: primary, fallbacks: [fallback] } }, models: [
    { id: primary, provider: 'anthropic', display_name: 'Claude Fable 5.1' }, { id: fallback, provider: 'anthropic', display_name: 'Claude Opus 5' }
  ] };
  const account = { name: 'Work', provider: 'anthropic', enabled: true, model_ids: [primary, fallback], model_cooldowns: { [primary]: now + 12000 }, usage: { observed_at: now, windows: [
    { name: '5h', remaining_ratio: .72, resets_at: now + 3600000 }, { name: 'weekly', remaining_ratio: .4, resets_at: now + 86400000 },
    { name: 'weekly-opus', model_pool: 'opus', remaining_ratio: 0, resets_at: now + 7200000 }
  ] } };
  let rows = cli.accountRows([account], now, undefined, config);
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0], ['Work', '-', 'anthropic', 'Fable 5.1', 'rate limited (12s)', '72%', '1h 0m', '40%', '1d 0h', '-', '-']);
  assert.deepEqual(rows[1], ['Work', '-', 'anthropic', 'Opus 5', 'weekly-opus quota exhausted', '72%', '1h 0m', '40%', '1d 0h', '0%', '2h 0m']);
  account.usage.windows[2].remaining_ratio = .3;
  rows = cli.accountRows([account], now, undefined, config);
  assert.equal(rows[1][4], 'ready', 'a primary model cooldown leaves the fallback available');
  account.model_ids = [primary];
  assert.equal(cli.accountRows([account], now, undefined, config)[1][4], 'not available');
  account.model_ids = [primary, fallback]; account.usage_error = 'unavailable';
  assert.match(cli.accountRows([account], now, undefined, config)[1][5], /stale/);
  config.models.push({ id: 'openai/test', provider: 'openai' });
  config.phases[2].fallbacks.push('openai/test');
  assert.equal(cli.accountRows([{ name: 'Personal', provider: 'openai', enabled: true }], now, undefined, config)[0][3], 'test');
  config.models.push({ id: 'openai/client-test', provider: 'openai' });
  config.client_routes = { codex: { model: 'openai/client-test', fallbacks: ['openai/test'] } };
  assert.deepEqual(cli.accountRows([{ name: 'Personal', provider: 'openai', enabled: true }], now, undefined, config).map(row => row[3]), ['test', 'client-test']);
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
    ['Main', '-', 'anthropic', '-', 'ready', '72%', '2h 14m', '40%', '3d 4h', '0%', 'due'],
    ['Personal', '-', 'openai', '-', 'ready', '-', '-', '91%', 'unknown', '-', '-'],
    ['Backup', '-', 'openai', '-', 'disabled', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown']
  ]);
  account.usage_error = 'Refresh failed';
  assert.match(cli.accountRows([account], now)[0][5], /stale/);
  account.status = 'reauth-required';
  account.cooldown_until = now + 60000;
  assert.equal(cli.accountRows([account], now)[0][4], 'reauth-required');
});
test('account rows list ranked accounts first regardless of registry order', () => {
  const now = Date.now();
  // Reauth re-appends an account, so the registry can hold rank 1 after rank 2 and an unranked newcomer.
  const items = [
    { id: 'spare', name: 'Spare', provider: 'anthropic', enabled: true, rank: 2, created_at: 1 },
    { id: 'new', name: 'New', provider: 'anthropic', enabled: true, created_at: 4 },
    { id: 'old', name: 'Old', provider: 'openai', enabled: true, created_at: 3 },
    { id: 'main', name: 'Main', provider: 'anthropic', enabled: true, rank: 1, created_at: 2 }
  ];
  assert.deepEqual(cli.accountRows(items, now).map(row => row[0]), ['Main', 'Spare', 'Old', 'New']);
  assert.deepEqual(policy.rankOrder(items).map(account => account.id), ['main', 'spare', 'old', 'new']);
  assert.deepEqual(items.map(account => account.id), ['spare', 'new', 'old', 'main'], 'ordering does not mutate the registry');
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
  assert.match(run(['accounts']), /Account +Rank +Provider +Model +Status +5h left +Reset in +Weekly left +Reset in/);
  assert.match(run(['accounts']), /Shared quota is repeated across model rows/);
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
  await cli.routeCommand('configure', ['openai/codex-test'], { client: 'codex', fallback: ['anthropic/claude-test'], effort: 'xhigh' });
  assert.equal(Object.keys(state.config().phases).length, 7);
  assert.equal(state.config().phases[2].model, 'openai/codex-test');
  assert.equal(state.config().phases[3].model, 'anthropic/claude-test');
  assert.deepEqual(state.config().client_routes.codex, { model: 'openai/codex-test', fallbacks: ['anthropic/claude-test'], effort: 'xhigh' });
  await assert.rejects(cli.routeCommand('configure', ['openai/codex-test'], { client: 'codex', phase: 'setup', fallback: [] }), /either --client or --phase/);
  await assert.rejects(cli.routeCommand('configure', ['unknown/model'], { fallback: [] }), /model/);
  await assert.rejects(cli.modelCommand('add', ['openai/test'], { context: '-1' }), /context/);
  // A running session launched at the 128k budget does not block a smaller fallback from joining the route.
  await cli.modelCommand('add', ['openai/small-test'], { ...options, context: '16000' });
  const { processIdentity } = require('../scripts/ccr/service.cjs');
  state.write(state.sessionFile('running'), { version: 1, id: 'running', active: true, owner_pid: process.pid, owner_identity: processIdentity(process.pid), context_limit: 128000, fixed_phase: 0 });
  await cli.routeCommand('configure', ['anthropic/claude-test'], { fallback: ['openai/small-test'] });
  assert.deepEqual(state.config().phases[0].fallbacks, ['openai/small-test']);
  assert.equal(policy.contextLimit(state.config()), 16000, 'new sessions launch at the smaller budget');
  await assert.rejects(cli.routeCommand('configure', ['anthropic/claude-test'], { fallback: ['openai/missing'] }), /not configured/, 'unknown models are still rejected for running sessions');
});
test('account controls preserve identity and delete selected credentials only', async () => {
  state.saveAccounts([{ id: 'one', name: 'Personal', provider: 'openai', enabled: true, created_at: 1 }, { id: 'two', name: 'Work', provider: 'openai', enabled: true, created_at: 2 }]);
  const store = new CredentialStore('linux'); store.set('one', { refresh_token: 'synthetic-one' }); store.set('two', { refresh_token: 'synthetic-two' });
  await onboarding.changeAccount('disable', 'Personal', null, store);
  assert.equal(state.getAccount('Personal').enabled, false);
  await onboarding.changeAccount('rank', 'Work', '1', store);
  assert.deepEqual(state.accounts().map(account => [account.name, account.rank]), [['Work', 1], ['Personal', 2]]);
  await assert.rejects(onboarding.changeAccount('rank', 'Work', '3', store), /between 1 and 2/);
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
test('discovery preserves default and maximum subscription windows without inventing larger limits', () => {
  const [model] = onboarding.catalogue('openai', { models: [{ slug: 'test', context_window: 272000, max_context_window: 872000 }] });
  assert.equal(model.context_window, 272000);
  assert.equal(model.default_context_window, 272000);
  assert.equal(model.max_context_window, 872000);
  for (const maximum of [null, -1, '872000', 1000, 5000000, 128000]) {
    assert.equal(onboarding.catalogue('openai', { models: [{ slug: 'test', context_window: 272000, max_context_window: maximum }] })[0].max_context_window, 272000);
  }
  const [claude] = onboarding.catalogue('anthropic', { data: [{ id: 'claude-test', max_input_tokens: 1000000, max_tokens: 128000 }] });
  assert.equal(claude.max_context_window, 1000000);
  assert.equal(claude.max_output_tokens, 128000);
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
  const original = { ANTHROPIC_API_KEY: 'bad', OPENAI_API_KEY: 'bad', CCR_WEB_AUTH_TOKEN: 'bad', DX_ROUTER_SESSION_TOKEN: 'parent-session-token', PATH: '/bin', CLAUDE_CONFIG_DIR: directory };
  const env = launchEnvironment({ gateway: 'http://127.0.0.1:1234' }, 'synthetic-session-token', { id: 'run1', context_limit: 128000 }, original);
  assert.equal(env.ANTHROPIC_API_KEY, undefined); assert.equal(env.CCR_WEB_AUTH_TOKEN, undefined);
  assert.equal(env.ANTHROPIC_AUTH_TOKEN, 'synthetic-session-token'); assert.equal(env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, '128000');
  assert.equal(env.DX_ROUTER_SESSION_TOKEN, 'synthetic-session-token'); assert.equal(env.DX_ROUTER_SESSION_ID, 'run1');
  assert.equal(parsed.args.includes('synthetic-session-token'), false);
  // A gateway launch is never first-party, so a name the client recognises
  // resolves to its believed 200k window and ignores CLAUDE_CODE_MAX_CONTEXT_TOKENS.
  // The marker lifts that; the window states the route's budget in tokens.
  assert.equal(env.ANTHROPIC_CUSTOM_MODEL_OPTION, 'dex/active[1m]');
  assert.equal(env.CLAUDE_CODE_SUBAGENT_MODEL, 'dex/active[1m]');
  assert.equal(env.ANTHROPIC_DEFAULT_OPUS_MODEL, 'dex/active[1m]');
  assert.equal(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '128000');
  // A routed base URL is never first-party, so the client would inline every
  // tool schema into every request unless Dex opts back in.
  assert.equal(env.ENABLE_TOOL_SEARCH, 'true');
  // Compaction scheduling stays the client's own.
  assert.equal(env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, undefined);
  assert.equal(env.ANTHROPIC_BETAS, 'context-1m-2025-08-07');
  const carried = launchEnvironment({ gateway: 'http://127.0.0.1:1234' }, 'synthetic-session-token', { id: 'run1', context_limit: 128000 },
    { ...original, ANTHROPIC_BETAS: ' fine-grained-tool-streaming-2025-05-14 , context-1m-2025-08-07 ' });
  assert.equal(carried.ANTHROPIC_BETAS, 'fine-grained-tool-streaming-2025-05-14,context-1m-2025-08-07');
  // With the native apiKeyHelper installed, Claude gets the capability from the helper only.
  fs.writeFileSync(path.join(directory, 'settings.json'), JSON.stringify({ apiKeyHelper: 'node native.cjs auth claude' }));
  const helped = launchEnvironment({ gateway: 'http://127.0.0.1:1234' }, 'synthetic-session-token', { id: 'run1', context_limit: 128000 }, original);
  assert.equal(helped.ANTHROPIC_AUTH_TOKEN, undefined); assert.equal(helped.DX_ROUTER_SESSION_TOKEN, 'synthetic-session-token');
  assert.equal(helped.ANTHROPIC_BASE_URL, 'http://127.0.0.1:1234/plugins/dex');
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
  assert.equal(result.status, 0); assert.match(result.stdout, /last: openai\/test \/ Main \/ 5h 40%/);
  state.write(state.sessionFile('current'), { current_account: 'one', current_model: 'openai/test', last_rejection: { model: 'anthropic/test', status: 400 } });
  const rejected = spawnSync('python3', ['scripts/router-status.py'], { encoding: 'utf8', env: { ...process.env, DX_ROUTER_SESSION_ID: 'current' } });
  assert.match(rejected.stdout, /anthropic\/test rejected request \(HTTP 400\)/);
  assert.doesNotMatch(rejected.stdout, /openai|Main|40%/);
});
test('CLI errors and machine output work from a separate process', () => {
  const run = args => spawnSync(process.execPath, [path.resolve('scripts/ccr/cli.cjs'), ...args], { encoding: 'utf8', env: { ...process.env, DEX_ROUTER_HOME: directory } });
  assert.deepEqual(JSON.parse(run(['accounts', '--json']).stdout).accounts, []);
  assert.notEqual(run(['account', 'show', 'missing']).status, 0);
  assert.match(run(['account', 'show', 'missing']).stderr, /Account not found/);
  assert.notEqual(run(['route', 'use', 'openai/test']).status, 0);
});

test('a metered model keeps a stable Dex ID separate from its upstream ID', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-metered-'));
  const prior = process.env.DEX_ROUTER_HOME; process.env.DEX_ROUTER_HOME = dir;
  t.after(() => { if (prior === undefined) delete process.env.DEX_ROUTER_HOME; else process.env.DEX_ROUTER_HOME = prior; fs.rmSync(dir, { recursive: true, force: true }); });
  t.mock.method(adapter, 'health', async () => null);
  const model = await cli.modelCommand('add', ['openrouter/glm-5.3'],
    cli.parse(['--context', '1048576', '--max-context', '1310720', '--tools', '--upstream', 'z-ai/glm-5.3']));
  assert.equal(model.id, 'openrouter/glm-5.3');
  assert.equal(model.upstream_id, 'z-ai/glm-5.3', 'the vendor segment stays out of the Dex ID');
  assert.equal(model.max_context_window, 1310720);
  assert.equal(model.capabilities.images, false);
  // What the gateway is told to call it, built the same way the router builds it.
  assert.equal(`dex-${model.provider}/${model.upstream_id}`, 'dex-openrouter/z-ai/glm-5.3');
  await assert.rejects(cli.modelCommand('add', ['openrouter/bad'], cli.parse(['--context', '200000', '--tools', '--upstream', 'has space'])), /upstream model ID/);
  await assert.rejects(cli.modelCommand('add', ['openrouter/small'], cli.parse(['--context', '200000', '--tools', '--max-context', '1000'])), /maximum context window/);
  await assert.rejects(cli.modelCommand('add', ['nope/model'], cli.parse(['--context', '200000', '--tools'])), /openrouter/);
});

test('profiles name the role a model plays and routes re-point without edits', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-profile-'));
  const prior = process.env.DEX_ROUTER_HOME; process.env.DEX_ROUTER_HOME = dir;
  t.after(() => { if (prior === undefined) delete process.env.DEX_ROUTER_HOME; else process.env.DEX_ROUTER_HOME = prior; fs.rmSync(dir, { recursive: true, force: true }); });
  t.mock.method(adapter, 'health', async () => null);
  for (const id of ['openrouter/glm-5.3', 'anthropic/claude-fable-5-1', 'anthropic/claude-opus-5'])
    await cli.modelCommand('add', [id], cli.parse(['--context', '200000', '--tools']));
  await cli.profileCommand('set', ['cheap', 'openrouter/glm-5.3'], {});
  await cli.profileCommand('set', ['near_frontier', 'anthropic/claude-fable-5-1'], {});
  await cli.routeCommand('configure', ['@cheap'], cli.parse(['--phase', 'implement', '--fallback', '@near_frontier', '--effort', 'high']));
  let config = state.config();
  assert.equal(config.phases[2].model, '@cheap', 'the profile name is stored, not its current model');
  // The saved route resolves at read time, so re-pointing the profile follows.
  assert.deepEqual(policy.route(config, { fixed_phase: 2 }).models.map(m => m.id), ['openrouter/glm-5.3', 'anthropic/claude-fable-5-1']);
  await cli.profileCommand('set', ['cheap', 'anthropic/claude-opus-5'], {});
  config = state.config();
  assert.deepEqual(policy.route(config, { fixed_phase: 2 }).models.map(m => m.id), ['anthropic/claude-opus-5', 'anthropic/claude-fable-5-1']);
  const profiles = await cli.profileCommand('list', [], {});
  assert.deepEqual(profiles.map(p => p.name).sort(), ['cheap', 'near_frontier']);
  // Clearing one a route still names is refused, and says which routes.
  await assert.rejects(cli.profileCommand('clear', ['cheap'], {}), /named by phase 2/);
  await cli.routeCommand('configure', ['anthropic/claude-opus-5'], cli.parse(['--phase', 'implement']));
  await cli.profileCommand('clear', ['cheap'], {});
  assert.equal(state.config().profiles.cheap, undefined);
  await assert.rejects(cli.profileCommand('set', ['BadName', 'anthropic/claude-opus-5'], {}), /profile name/i);
  await assert.rejects(cli.routeCommand('configure', ['@ghost'], cli.parse(['--phase', 'review'])), /Profile ghost is not assigned/);
});
