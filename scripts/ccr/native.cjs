'use strict';
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const state = require('./state.cjs');
const policy = require('./policy.cjs');
const ipc = require('./ipc.cjs');
const adapter = require('./adapter.cjs');
const { claudePicker, betaHeader, longContext, plainModel } = require('./claude-picker.cjs');

const quote = value => `'${String(value).replace(/'/g, `'\\''`)}'`;
const authArgs = client => [path.join(__dirname, 'native.cjs'), 'auth', client, state.root()];

function ownerPid(pid = process.ppid) {
  for (let hop = 0; hop < 8 && pid > 1; hop++) {
    const result = spawnSync('ps', ['-p', String(pid), '-o', 'ppid=', '-o', 'comm='], { encoding: 'utf8', timeout: 3000 });
    const match = result.status === 0 && result.stdout.trim().match(/^(\d+)\s+(.+)$/);
    if (!match) break;
    if (!['sh', 'bash', 'zsh', 'fish', 'dash', 'env'].includes(path.basename(match[2]))) return pid;
    pid = Number(match[1]);
  }
  throw new Error('Could not identify the native client requesting authentication.');
}

async function authenticate(client) {
  if (!['claude', 'codex'].includes(client)) throw new Error('Expected claude or codex.');
  // A routed Dex launch already holds a session capability; the helper hands it back.
  const routed = process.env.DX_ROUTER_SESSION_TOKEN || process.env.ANTHROPIC_AUTH_TOKEN;
  if (client === 'claude' && process.env.DX_ROUTER_SESSION_ID && routed) return routed;
  const owner_pid = ownerPid();
  if (!await adapter.health(true)) await adapter.start({ recovery: Boolean(state.backend(null)) });
  const result = await ipc.call('native-auth', { client, owner_pid }, 30000);
  return result.token;
}

function clientSettings(action, native, settings, config) {
  const backup = path.join(state.privateDir(path.join(state.root(), 'credentials')), 'native-client-settings.json');
  const request = { action, backup, claude_file: native.claude_file, codex_file: native.codex_file };
  if (action !== 'disable') config ||= state.config();
  if (action === 'sync-context') {
    request.claude_picker = claudePicker(config, 'claude');
    request.claude_betas = betaHeader(process.env.ANTHROPIC_BETAS);
    request.claude_tool_search = 'true';
    request.claude_context = policy.contextLimit(config, 'claude');
    request.claude_compact_window = request.claude_context;
    // Only a model this route actually offers is re-marked; anything else is the user's.
    request.claude_models = request.claude_picker.options.map(option => plainModel(option.model));
    request.codex_context = policy.contextLimit(config, 'codex');
  } else if (action !== 'disable') {
    const claudeContext = policy.contextLimit(config, 'claude');
    const codexContext = policy.contextLimit(config, 'codex');
    const helper = [process.execPath, ...authArgs('claude')].map(quote).join(' ');
    request.claude_fields = [
      { field: ['apiKeyHelper'], value: helper },
      { field: ['model'], value: longContext('dex/active') },
      { field: ['modelPicker'], value: claudePicker(config, 'claude') },
      { field: ['env', 'ANTHROPIC_BASE_URL'], value: `${settings.gateway}/plugins/dex` },
      { field: ['env', 'ANTHROPIC_BETAS'], value: betaHeader(process.env.ANTHROPIC_BETAS) },
      { field: ['env', 'ANTHROPIC_CUSTOM_MODEL_OPTION'], value: longContext('dex/active') },
      { field: ['env', 'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME'], value: 'Dex automatic route' },
      ...['OPUS', 'SONNET', 'HAIKU'].map(name => ({ field: ['env', `ANTHROPIC_DEFAULT_${name}_MODEL`], value: longContext('dex/active') })),
      { field: ['env', 'CLAUDE_CODE_SUBAGENT_MODEL'], value: longContext('dex/active') },
      { field: ['env', 'ENABLE_TOOL_SEARCH'], value: 'true' },
      { field: ['env', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS'], value: String(claudeContext) },
      { field: ['env', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'], value: String(claudeContext) }
    ];
    request.codex_fields = [
      { field: 'model_provider', value: 'dex-ccr' }, { field: 'model', value: 'dex/active' },
      { field: 'model_context_window', value: codexContext }, { field: 'model_auto_compact_token_limit', value: Math.floor(codexContext * 0.8) }
    ];
    request.provider_content = [
      '# Dex native routing: managed provider',
      '[model_providers.dex-ccr]', 'name = "Dex subscription accounts"',
      `base_url = ${JSON.stringify(`${settings.gateway}/plugins/dex/v1`)}`,
      'wire_api = "responses"', 'supports_websockets = false',
      '', '[model_providers.dex-ccr.auth]',
      `command = ${JSON.stringify(process.execPath)}`, `args = ${JSON.stringify(authArgs('codex'))}`,
      'timeout_ms = 45000', 'refresh_interval_ms = 300000', '# End Dex native routing', ''
    ].join('\n');
  }
  const result = spawnSync('python3', [path.join(__dirname, 'native-config.py')], { input: JSON.stringify(request), encoding: 'utf8', timeout: 10000 });
  if (result.status !== 0) throw new Error(result.stderr.trim() || 'Native client configuration failed.');
  return JSON.parse(result.stdout);
}

// Called while holding the config lock. This also repairs settings installed
// before native clients had separate routes, without resetting /model choices.
function syncContext(config = state.config()) {
  if (!config.enabled || !config.native?.enabled) return;
  return clientSettings('sync-context', config.native, null, config);
}

async function disable({ router = false } = {}) {
  return state.locked('config', () => {
    const config = state.config();
    const restored = config.native?.enabled ? clientSettings('disable', config.native, null) : null;
    if (config.native) config.native.enabled = false;
    if (router) config.enabled = false;
    if (restored || router) state.write(state.stateFile('config'), config);
    if (!restored) return 'Native routing is already disabled.';
    return `Native routing disabled. Previous client defaults restored.${restored.preserved.length ? ` Kept your edits to ${restored.preserved.join(', ')}.` : ''}`;
  });
}

async function command(action = 'status') {
  if (action === 'status') {
    const native = state.config().native;
    return native?.enabled ? 'Plain claude and codex launches use Dex routing. Run dx router native disable to restore independent native launches.'
      : 'Plain claude and codex launches use their native configuration. Dex routing is scoped to the ccr-subscription profile.';
  }
  if (action === 'sync' && !state.config().native?.enabled) return;
  if (!['enable', 'disable', 'sync'].includes(action)) throw new Error('Use dx router native enable, disable or status.');
  if (action === 'disable') return disable();
  const settings = action === 'enable' ? await adapter.start() : state.backend(null);
  if (action === 'enable' && !(await ipc.call('health')).capabilities?.includes('native-auth')) throw new Error('The running gateway needs the native routing update. Finish its sessions, run dx router restart, then enable native routing.');
  return state.locked('config', () => {
    const config = state.config();
    const native = { ...config.native };
    if (!config.enabled) throw new Error('Run dx router setup first.');
    native.claude_file ||= path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'settings.json');
    native.codex_file ||= path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'config.toml');
    policy.contextLimit(config);
    clientSettings('enable', native, settings);
    config.native = { ...native, enabled: true }; state.write(state.stateFile('config'), config);
    return 'Native routing enabled. Run claude or codex; CCR starts when the client requests authentication. Use dx accounts --live to watch usage.';
  });
}

if (require.main === module) {
  process.umask(0o077);
  const [action, client, root] = process.argv.slice(2);
  if (root) process.env.DEX_ROUTER_HOME = root;
  const operation = action === 'auth' ? authenticate(client) : command(action);
  operation.then(result => { if (result) process.stdout.write(`${result}\n`); }).catch(error => { process.stderr.write(`dex: ${error.message}\n`); process.exitCode = 1; });
}
module.exports = { ownerPid, authenticate, clientSettings, syncContext, disable, command };
