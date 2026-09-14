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
  const previousId = process.env.DX_ROUTER_SESSION_ID; const previousToken = process.env.ANTHROPIC_AUTH_TOKEN;
  process.env.DX_ROUTER_SESSION_ID = 'existing-dex-session'; process.env.ANTHROPIC_AUTH_TOKEN = 'synthetic-scoped-capability';
  try {
    assert.equal(await native.authenticate('claude'), 'synthetic-scoped-capability');
    assert.deepEqual(state.sessions(), []);
  } finally {
    if (previousId === undefined) delete process.env.DX_ROUTER_SESSION_ID; else process.env.DX_ROUTER_SESSION_ID = previousId;
    if (previousToken === undefined) delete process.env.ANTHROPIC_AUTH_TOKEN; else process.env.ANTHROPIC_AUTH_TOKEN = previousToken;
  }
});

test('native settings preserve client preferences and restore only managed values', () => {
  native.clientSettings('enable', config, settings);
  let claude = JSON.parse(fs.readFileSync(config.claude_file));
  assert.deepEqual(claude.permissions, original.permissions); assert.deepEqual(claude.hooks, original.hooks);
  assert.equal(claude.env.KEEP_ME, 'yes'); assert.equal(claude.model, 'dex/active');
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
