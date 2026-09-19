'use strict';
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const state = require('../scripts/ccr/state.cjs');
const native = require('../scripts/ccr/native.cjs');
let directory, settings, config, original;

beforeEach(() => {
  directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-native-settings-'));
  process.env.DEX_ROUTER_HOME = directory;
  settings = { gateway: 'http://127.0.0.1:34567' };
  config = { claude_file: path.join(directory, 'claude/settings.json'), codex_file: path.join(directory, 'codex/config.toml') };
  fs.mkdirSync(path.dirname(config.claude_file)); fs.mkdirSync(path.dirname(config.codex_file));
  original = { model: 'opus', permissions: { defaultMode: 'default' }, env: { KEEP_ME: 'yes' }, hooks: { Stop: [] } };
  fs.writeFileSync(config.claude_file, JSON.stringify(original));
  fs.writeFileSync(config.codex_file, '# Personal config\nmodel = "personal-model"\nmodel_provider = "work" # Keep my default\n[mcp_servers.example]\ncommand = "example"\n');
  state.write(state.stateFile('config'), { version: 1, enabled: true, phases: { 0: { model: 'anthropic/test', fallbacks: ['openai/test'] } }, default_model: 'anthropic/test', models: ['anthropic/test', 'openai/test'].map(id => ({ id, provider: id.split('/')[0], context_window: 128000 })) });
});
afterEach(() => fs.rmSync(directory, { recursive: true, force: true }));

function toml(file) {
  const result = spawnSync('python3', ['-c', 'import json,sys,tomllib; print(json.dumps(tomllib.loads(sys.stdin.read())))'], { input: fs.readFileSync(file, 'utf8'), encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
}

test('Claude launched by Dex retains its existing session capability and phase routing', async () => {
  const saved = Object.fromEntries(['DX_ROUTER_SESSION_ID', 'DX_ROUTER_SESSION_TOKEN', 'ANTHROPIC_AUTH_TOKEN'].map(key => [key, process.env[key]]));
  process.env.DX_ROUTER_SESSION_ID = 'existing-dex-session'; process.env.ANTHROPIC_AUTH_TOKEN = 'synthetic-scoped-capability';
  delete process.env.DX_ROUTER_SESSION_TOKEN;
  try {
    assert.equal(await native.authenticate('claude'), 'synthetic-scoped-capability');
    // The helper-only launch keeps ANTHROPIC_AUTH_TOKEN out of Claude's environment.
    delete process.env.ANTHROPIC_AUTH_TOKEN; process.env.DX_ROUTER_SESSION_TOKEN = 'synthetic-helper-capability';
    assert.equal(await native.authenticate('claude'), 'synthetic-helper-capability');
    assert.deepEqual(state.sessions(), []);
  } finally {
    for (const [key, value] of Object.entries(saved)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  }
});

test('native settings preserve client preferences and restore only managed values', () => {
  native.clientSettings('enable', config, settings);
  let claude = JSON.parse(fs.readFileSync(config.claude_file));
  assert.deepEqual(claude.permissions, original.permissions); assert.deepEqual(claude.hooks, original.hooks);
  assert.equal(claude.env.KEEP_ME, 'yes'); assert.equal(claude.model, 'dex/active[1m]');
  assert.equal(claude.modelPicker.replaceBuiltInOptions, true);
  assert.equal(claude.modelPicker.options.filter(option => option.model === 'dex/active[1m]').length, 1);
  assert.match(claude.apiKeyHelper, /native\.cjs.*auth.*claude/);
  const codex = toml(config.codex_file);
  assert.equal(codex.model_provider, 'dex-ccr'); assert.equal(codex.model, 'dex/active');
  assert.equal(codex.mcp_servers.example.command, 'example');
  assert.equal(codex.model_providers['dex-ccr'].wire_api, 'responses');
  assert.deepEqual(codex.model_providers['dex-ccr'].auth.args.slice(1), ['auth', 'codex', directory]);
  assert.equal(codex.model_providers['dex-ccr'].env_key, undefined);
  native.clientSettings('enable', config, settings);
  claude.env.ADDED_LATER = 'retained'; fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  native.clientSettings('disable', config, settings);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), { ...original, env: { ...original.env, ADDED_LATER: 'retained' } });
  assert.equal(toml(config.codex_file).model_provider, 'work');
  assert.equal(toml(config.codex_file).model, 'personal-model');
  assert.equal(toml(config.codex_file).model_providers, undefined);
});

test('native picker migration restores the previous lineup and preserves later user edits', () => {
  native.clientSettings('enable', config, settings);
  const backup = path.join(directory, 'credentials/native-client-settings.json');
  const saved = JSON.parse(fs.readFileSync(backup));
  saved.claude = saved.claude.filter(entry => entry.field[0] !== 'modelPicker');
  state.write(backup, saved);
  const personal = { options: [{ model: 'opus', label: 'Personal Opus' }] };
  const claude = JSON.parse(fs.readFileSync(config.claude_file));
  claude.modelPicker = personal; fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  native.syncContext(routing);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).modelPicker.options[0].label, 'CCR subscription');
  native.clientSettings('disable', config, settings);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)).modelPicker, personal);
  native.clientSettings('enable', config, settings);
  const edited = JSON.parse(fs.readFileSync(config.claude_file)); edited.modelPicker = personal;
  fs.writeFileSync(config.claude_file, JSON.stringify(edited));
  native.syncContext(routing);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)).modelPicker, personal);
  assert.ok(native.clientSettings('disable', config, settings).preserved.includes('claude.modelPicker'));
});

test('native settings request the long-context beta and adopt it on installs that predate the field', () => {
  native.clientSettings('enable', config, settings);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.ANTHROPIC_BETAS, 'context-1m-2025-08-07');
  // An install from before Dex managed this field has no ownership record for
  // it. Enable refuses to run once any managed value carries a personal edit,
  // so a context sync is the migration these installations actually reach.
  const backup = path.join(directory, 'credentials/native-client-settings.json');
  const saved = JSON.parse(fs.readFileSync(backup));
  saved.claude = saved.claude.filter(entry => entry.field[1] !== 'ANTHROPIC_BETAS');
  state.write(backup, saved);
  const claude = JSON.parse(fs.readFileSync(config.claude_file));
  claude.env.ANTHROPIC_BETAS = 'personal-beta-2025-01-01'; claude.model = 'anthropic/test';
  fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  native.syncContext(routing);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.ANTHROPIC_BETAS, 'context-1m-2025-08-07');
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).model, 'anthropic/test[1m]', 'a /model choice survives the migration and gains the long-context marker');
  native.clientSettings('disable', config, settings);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.ANTHROPIC_BETAS, 'personal-beta-2025-01-01');
  // A beta the user changes after the migration stays theirs.
  native.clientSettings('enable', config, settings);
  const edited = JSON.parse(fs.readFileSync(config.claude_file));
  edited.env.ANTHROPIC_BETAS = 'chosen-by-hand'; fs.writeFileSync(config.claude_file, JSON.stringify(edited));
  native.syncContext(routing);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.ANTHROPIC_BETAS, 'chosen-by-hand');
  assert.ok(native.clientSettings('disable', config, settings).preserved.includes('claude.env.ANTHROPIC_BETAS'));
  // A beta the user exported for their own launches survives alongside ours.
  const exported = process.env.ANTHROPIC_BETAS;
  process.env.ANTHROPIC_BETAS = ' fine-grained-tool-streaming-2025-05-14 , context-1m-2025-08-07 ';
  try {
    fs.writeFileSync(config.claude_file, JSON.stringify(original));
    native.clientSettings('enable', config, settings);
    assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.ANTHROPIC_BETAS,
      'fine-grained-tool-streaming-2025-05-14,context-1m-2025-08-07');
  } finally {
    if (exported === undefined) delete process.env.ANTHROPIC_BETAS; else process.env.ANTHROPIC_BETAS = exported;
  }
  native.clientSettings('disable', config, settings);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
});

test('disabled native routing survives tooling sync and route changes without editing either CLI', async t => {
  native.clientSettings('enable', config, settings);
  const routing = state.config(); routing.native = { ...config, enabled: true };
  state.write(state.stateFile('config'), routing);
  t.mock.method(require('../scripts/ccr/adapter.cjs'), 'start', () => { throw new Error('Native recovery must work without CCR'); });
  await native.command('disable');
  const files = [config.claude_file, config.codex_file];
  const before = files.map(file => fs.readFileSync(file, 'utf8'));
  await native.command('sync');
  await require('../scripts/ccr/cli.cjs').routeCommand('configure', ['openai/test'], { fallback: [] });
  assert.deepEqual(files.map(file => fs.readFileSync(file, 'utf8')), before);
  assert.equal(state.config().native.enabled, false);
  assert.equal(state.config().enabled, true, 'Dex routing remains available');
  assert.match(await native.command('status'), /native configuration/);
});

test('router disable restores native clients offline despite invalid routes and retains accounts and sessions', async t => {
  native.clientSettings('enable', config, settings);
  const routing = state.config(); routing.native = { ...config, enabled: true }; routing.default_model = 'anthropic/missing'; routing.models = [];
  state.write(state.stateFile('config'), routing);
  fs.writeFileSync(state.stateFile('backend'), 'broken backend metadata', { mode: 0o600 });
  state.saveAccounts([{ id: 'saved', enabled: true, provider: 'anthropic' }]);
  const session = { id: 'running', active: true, current_model: 'anthropic/test' };
  state.write(state.sessionFile('running'), session);
  t.mock.method(require('../scripts/ccr/adapter.cjs'), 'start', () => { throw new Error('Rescue must not start the gateway'); });
  t.mock.method(state, 'sessions', () => { throw new Error('Rescue must not inspect active sessions'); });
  const cli = require('../scripts/ccr/cli.cjs');
  assert.match(await cli.routerCommand('disable', {}), /Start a new terminal session and run claude or codex/);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
  assert.equal(toml(config.codex_file).model_provider, 'work');
  assert.equal(state.config().enabled, false);
  assert.equal(state.config().native.enabled, false);
  assert.deepEqual(state.config().phases, routing.phases);
  assert.equal(state.accounts()[0].id, 'saved');
  assert.deepEqual(state.read(state.sessionFile('running')), session);
  const before = [config.claude_file, config.codex_file].map(file => fs.readFileSync(file, 'utf8'));
  await cli.routerCommand('disable', {});
  assert.deepEqual([config.claude_file, config.codex_file].map(file => fs.readFileSync(file, 'utf8')), before);
});

test('router enable after rescue leaves native CLI routing off', async t => {
  native.clientSettings('enable', config, settings);
  const routing = state.config(); routing.native = { ...config, enabled: true }; state.write(state.stateFile('config'), routing);
  const cli = require('../scripts/ccr/cli.cjs');
  await cli.routerCommand('disable', {});
  const before = [config.claude_file, config.codex_file].map(file => fs.readFileSync(file, 'utf8'));
  const start = t.mock.method(require('../scripts/ccr/adapter.cjs'), 'start', async () => settings);
  await cli.routerCommand('enable', {});
  assert.equal(start.mock.callCount(), 1);
  assert.equal(state.config().enabled, true);
  assert.equal(state.config().native.enabled, false);
  assert.deepEqual([config.claude_file, config.codex_file].map(file => fs.readFileSync(file, 'utf8')), before);
});

test('native settings use the context budget for each client route', () => {
  const routing = state.config();
  routing.models.find(model => model.id === 'openai/test').context_window = 64000;
  routing.client_routes = {
    claude: { model: 'anthropic/test', fallbacks: [] },
    codex: { model: 'openai/test', fallbacks: [] }
  };
  state.write(state.stateFile('config'), routing);
  native.clientSettings('enable', config, settings);
  const claude = JSON.parse(fs.readFileSync(config.claude_file));
  const codex = toml(config.codex_file);
  assert.equal(claude.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, '128000');
  assert.equal(codex.model_context_window, 64000);
  assert.equal(codex.model_auto_compact_token_limit, 51200);
});

test('route changes refresh installed context budgets without resetting model choices', async () => {
  native.clientSettings('enable', config, settings);
  fs.writeFileSync(config.codex_file, fs.readFileSync(config.codex_file, 'utf8').replace('model = "dex/active"', 'model = "test"'));
  const routing = state.config();
  routing.native = { ...config, enabled: true };
  routing.models.push({ id: 'openai/small', provider: 'openai', context_window: 64000 });
  state.write(state.stateFile('config'), routing);
  const claudeBefore = fs.readFileSync(config.claude_file, 'utf8');
  await require('../scripts/ccr/cli.cjs').routeCommand('configure', ['openai/test'], { client: 'codex', fallback: ['openai/small'] });
  const codex = toml(config.codex_file);
  assert.equal(codex.model, 'test');
  assert.equal(codex.model_context_window, 64000);
  assert.equal(codex.model_auto_compact_token_limit, 51200);
  assert.equal(fs.readFileSync(config.claude_file, 'utf8'), claudeBefore);
  native.clientSettings('disable', config, settings);
  assert.equal(toml(config.codex_file).model_context_window, undefined);
  assert.equal(toml(config.codex_file).model_auto_compact_token_limit, undefined);
  assert.equal(toml(config.codex_file).model, 'test');
});

test('context sync preserves an earlier personal compaction threshold', () => {
  native.clientSettings('enable', config, settings);
  fs.writeFileSync(config.codex_file, fs.readFileSync(config.codex_file, 'utf8').replace('model_auto_compact_token_limit = 102400', 'model_auto_compact_token_limit = 40000'));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  routing.models[1].context_window = 64000;
  native.syncContext(routing);
  assert.equal(toml(config.codex_file).model_context_window, 64000);
  assert.equal(toml(config.codex_file).model_auto_compact_token_limit, 40000);
  native.clientSettings('disable', config, settings);
  assert.equal(toml(config.codex_file).model_auto_compact_token_limit, 40000);
});

test('Claude compacts early and restores its earlier personal setting', () => {
  original.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = '60000';
  fs.writeFileSync(config.claude_file, JSON.stringify(original));
  native.clientSettings('enable', config, settings);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '60000');
  const routing = state.config(); routing.native = { ...config, enabled: true };
  native.syncContext(routing);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '60000');
  native.clientSettings('disable', config, settings);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
});

test('context sync hands compaction scheduling back to the client', () => {
  native.clientSettings('enable', config, settings);
  // An install from when Dex pinned the percentage against a believed 200k window.
  const backup = path.join(directory, 'credentials/native-client-settings.json');
  const saved = JSON.parse(fs.readFileSync(backup));
  saved.claude.push({ field: ['env', 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'], original: { present: false }, installed: '80' });
  state.write(backup, saved);
  const claude = JSON.parse(fs.readFileSync(config.claude_file));
  claude.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = '80';
  fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  native.syncContext(routing);
  const synced = JSON.parse(fs.readFileSync(config.claude_file));
  assert.equal(synced.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, undefined, 'Dex stops pinning the percentage');
  assert.equal(synced.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '128000', 'the route budget replaces it');
  assert.equal(JSON.parse(fs.readFileSync(backup)).claude.some(entry => entry.field.at(-1) === 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'), false);
  native.clientSettings('disable', config, settings);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
});

test('a percentage the user changed after the migration stays theirs', () => {
  native.clientSettings('enable', config, settings);
  const backup = path.join(directory, 'credentials/native-client-settings.json');
  const saved = JSON.parse(fs.readFileSync(backup));
  saved.claude.push({ field: ['env', 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'], original: { present: false }, installed: '80' });
  state.write(backup, saved);
  const claude = JSON.parse(fs.readFileSync(config.claude_file));
  claude.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = '55';
  fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  native.syncContext(routing);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, '55');
});

test('context sync migrates older Claude installations and can undo the migration', () => {
  native.clientSettings('enable', config, settings);
  const backup = path.join(directory, 'credentials/native-client-settings.json');
  const saved = JSON.parse(fs.readFileSync(backup));
  saved.claude = saved.claude.filter(entry => entry.field.at(-1) !== 'CLAUDE_CODE_AUTO_COMPACT_WINDOW');
  state.write(backup, saved);
  const claude = JSON.parse(fs.readFileSync(config.claude_file));
  delete claude.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW;
  fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  native.syncContext(routing);
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '128000');
  native.clientSettings('enable', config, settings);
  native.clientSettings('disable', config, settings);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
});

test('failed context sync rolls back the route and leaves client settings and ownership intact', async () => {
  native.clientSettings('enable', config, settings);
  const routing = state.config(); routing.native = { ...config, enabled: true };
  routing.models.push({ id: 'openai/small', provider: 'openai', context_window: 64000 });
  state.write(state.stateFile('config'), routing);
  fs.writeFileSync(config.codex_file, 'invalid TOML = [');
  const files = [config.claude_file, config.codex_file, path.join(directory, 'credentials/native-client-settings.json')];
  const before = files.map(file => fs.readFileSync(file, 'utf8'));
  await assert.rejects(require('../scripts/ccr/cli.cjs').routeCommand('configure', ['openai/small'], { client: 'codex', fallback: [] }), /Native client setup failed/);
  assert.deepEqual(state.config(), routing);
  assert.deepEqual(files.map(file => fs.readFileSync(file, 'utf8')), before);
});

test('catalogue changes synchronize context and compaction budgets too', async t => {
  native.clientSettings('enable', config, settings);
  const routing = state.config(); routing.native = { ...config, enabled: true };
  state.write(state.stateFile('config'), routing);
  t.mock.method(require('../scripts/ccr/adapter.cjs'), 'health', async () => null);
  await require('../scripts/ccr/cli.cjs').modelCommand('add', ['openai/test'], { context: '64000', tools: true });
  assert.equal(toml(config.codex_file).model_context_window, 64000);
  assert.equal(toml(config.codex_file).model_auto_compact_token_limit, 51200);
});

test('a personal threshold above the new budget rejects the route change without overwriting it', async () => {
  native.clientSettings('enable', config, settings);
  fs.writeFileSync(config.codex_file, fs.readFileSync(config.codex_file, 'utf8').replace('model_auto_compact_token_limit = 102400', 'model_auto_compact_token_limit = 90000'));
  const routing = state.config(); routing.native = { ...config, enabled: true };
  routing.models.push({ id: 'openai/small', provider: 'openai', context_window: 64000 });
  state.write(state.stateFile('config'), routing);
  const before = fs.readFileSync(config.codex_file, 'utf8');
  await assert.rejects(require('../scripts/ccr/cli.cjs').routeCommand('configure', ['openai/small'], { client: 'codex', fallback: [] }), /model_auto_compact_token_limit.*at most 51200/);
  assert.equal(fs.readFileSync(config.codex_file, 'utf8'), before);
  assert.deepEqual(state.config(), routing);
});

test('context sync leaves a client on a different provider untouched', () => {
  native.clientSettings('enable', config, settings);
  const codex = fs.readFileSync(config.codex_file, 'utf8').replace('model_provider = "dex-ccr"', 'model_provider = "work"');
  fs.writeFileSync(config.codex_file, codex);
  const routing = state.config(); routing.native = { ...config, enabled: true }; routing.models[1].context_window = 64000;
  native.syncContext(routing);
  assert.equal(fs.readFileSync(config.codex_file, 'utf8'), codex);
});

test('disable preserves routing settings the user changed after installation', () => {
  native.clientSettings('enable', config, settings);
  const claude = JSON.parse(fs.readFileSync(config.claude_file)); claude.model = 'user-choice';
  fs.writeFileSync(config.claude_file, JSON.stringify(claude));
  assert.throws(() => native.clientSettings('enable', config, settings), /settings were edited/);
  const result = native.clientSettings('disable', config, settings);
  assert.ok(result.preserved.includes('claude.model'));
  assert.equal(JSON.parse(fs.readFileSync(config.claude_file)).model, 'user-choice');
});

test('malformed config or an unowned provider leaves all client files unchanged', () => {
  fs.writeFileSync(config.codex_file, 'invalid TOML = [');
  assert.throws(() => native.clientSettings('enable', config, settings), /Native client setup failed/);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
  fs.writeFileSync(config.codex_file, 'model = "personal"\n[model_providers.dex-ccr]\nname = "User-owned"\n');
  assert.throws(() => native.clientSettings('enable', config, settings), /not owned by Dex/);
  assert.deepEqual(JSON.parse(fs.readFileSync(config.claude_file)), original);
});

test('TOML root edits respect multiline strings and arrays', () => {
  fs.writeFileSync(config.codex_file, 'instructions = """\n[not.a.table]\nmodel_provider = "in prose"\n"""\nvalues = [\n  ["nested array"]\n]\n"model_provider" = "work"\n[features]\nhooks = true\n');
  native.clientSettings('enable', config, settings);
  assert.equal(toml(config.codex_file).model_provider, 'dex-ccr');
  native.clientSettings('disable', config, settings);
  const restored = toml(config.codex_file);
  assert.equal(restored.model_provider, 'work'); assert.deepEqual(restored.values, [['nested array']]);
  assert.match(restored.instructions, /model_provider = "in prose"/);
});
