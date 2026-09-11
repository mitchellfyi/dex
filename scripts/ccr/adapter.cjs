'use strict';

const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const http = require('node:http');
const { spawn } = require('node:child_process');
const state = require('./state.cjs');
const ipc = require('./ipc.cjs');
const { nativeEnv } = require('./accounts.cjs');
const { active, processIdentity } = require('./service.cjs');

const RELEASE = '3.1.0-gateway-1.0.21';
const runtime = () => path.join(state.root(), 'runtimes', RELEASE);
const entry = directory => path.join(directory, 'node_modules', '@musistudio', 'claude-code-router', 'dist', 'main', 'cli.js');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function availablePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer(); server.once('error', reject);
    server.listen(0, '127.0.0.1', () => { const port = server.address().port; server.close(() => resolve(port)); });
  });
}
function idle() {
  if (state.sessions().some(active)) throw new Error('Routed sessions are active. Finish them before changing the CCR runtime or model catalogue.');
}
async function install() {
  return state.locked('runtime', async () => {
    idle();
    const directory = runtime();
    if (fs.existsSync(path.join(directory, 'installed.json'))) {
      try { verifyRuntime(directory); return directory; } catch { /* npm ci repairs the isolated tree below. */ }
    }
    await stopOwned(state.backend(null));
    state.privateDir(directory);
    for (const name of ['package.json', 'package-lock.json']) fs.copyFileSync(path.join(__dirname, 'runtime-package', name), path.join(directory, name));
    await new Promise((resolve, reject) => {
      const child = spawn('npm', ['ci', '--no-audit', '--no-fund'], { cwd: directory, stdio: ['inherit', process.stderr, 'inherit'], env: nativeEnv('anthropic', path.join(state.root(), 'unused-auth')) });
      child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(new Error('CCR installation failed. Run dx router install to retry.')));
    });
    verifyRuntime(directory);
    state.write(path.join(directory, 'installed.json'), { release: RELEASE, installed_at: Date.now() });
    return directory;
  });
}
function verifyRuntime(directory = runtime()) {
  for (const [name, version] of [['@musistudio/claude-code-router', '3.1.0'], ['@the-next-ai/ai-gateway', '1.0.21']]) {
    let actual; try { actual = JSON.parse(fs.readFileSync(path.join(directory, 'node_modules', name, 'package.json'), 'utf8')).version; } catch { /* Report the supported recovery below. */ }
    if (actual !== version) throw new Error('The pinned CCR runtime is missing or incompatible. Run dx router install.');
  }
  return entry(directory);
}
async function rpc(settings, method, args = [], timeout = 30000) {
  const response = await fetch(`${settings.management}/api/ccr/rpc`, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(timeout),
    headers: { 'content-type': 'application/json', 'x-ccr-web-auth': settings.management_key }, body: JSON.stringify({ method, args })
  });
  if (!response.ok) throw new Error(`CCR management request failed (${response.status}).`);
  const result = await response.json();
  if (!result.ok) throw new Error(`CCR rejected ${method}. Run dx router doctor.`);
  return result.value;
}
function managedConfig(base, settings, config, endpoints = {}, extension = path.join(__dirname, 'extension.cjs')) {
  const providers = ['anthropic', 'openai'].map(provider => ({
    id: `dex-${provider}`, name: `dex-${provider}`, enabled: true,
    type: provider === 'anthropic' ? 'anthropic_messages' : 'openai_responses',
    baseUrl: endpoints[provider] || (provider === 'anthropic' ? 'https://api.anthropic.com' : 'https://chatgpt.com/backend-api/codex'),
    apiKey: 'dex-extension-auth-required', autoFetchModels: false,
    models: config.models.filter(item => item.provider === provider).map(item => item.upstream_id || item.id.split('/')[1]),
    account: { enabled: true, connectors: [{ id: 'dex-subscriptions', type: 'plugin', pluginId: 'dex-subscriptions', connectorId: 'dex-subscription-usage' }] }
  })).filter(provider => provider.models.length);
  return {
    ...base, APIKEY: settings.client_key, APIKEYS: [{ id: 'dex-local', name: 'Dex local transport', key: settings.client_key, createdAt: new Date().toISOString() }], autoStart: false, launchAtLogin: false,
    HOST: '127.0.0.1', PORT: settings.gateway_port, Providers: providers, providerPlugins: [], virtualModelProfiles: [],
    gateway: { enabled: true, host: '127.0.0.1', port: settings.gateway_port, coreHost: '127.0.0.1', corePort: settings.core_port },
    Router: { ...base.Router, rules: [], fallback: { mode: 'off' }, builtInRules: { 'claude-code': { enabled: false }, codex: { enabled: false } } },
    proxy: { ...base.proxy, enabled: false, upstream: { ...base.proxy?.upstream, mode: 'none' } }, profile: { ...base.profile, enabled: false },
    agent: { ...base.agent, mcpServers: [] }, toolHub: { ...base.toolHub, enabled: false, mcpServers: [] },
    contextArchive: { ...base.contextArchive, enabled: false },
    observability: { agentAnalysis: false, requestLogs: false, requestLogBodyCapture: 'none', requestLogSuccessSampleRate: 0 },
    plugins: [{ id: 'dex-subscriptions', name: 'Dex subscriptions', enabled: true, module: extension,
      surfaces: { gateway: true, provider: true, apps: false }, permissions: ['trusted-code', 'gateway-routes', 'core-gateway-plugins', 'provider-account-connectors'] }]
  };
}
async function health(deep = false) {
  try {
    const result = await ipc.call('health', {}, 1500);
    if (result.version !== 1 || result.extension !== 'dex-ccr') return null;
    if (deep) {
      const settings = state.backend();
      if (processIdentity(settings.pid) !== settings.owner_identity || (await rpc(settings, 'getGatewayStatus', [], 2000)).state !== 'running') return null;
    }
    return result;
  } catch { return null; }
}
async function start({ directory = runtime(), endpoints, extension, recovery = false } = {}) {
  return state.locked('runtime', async () => {
    if (await health(true)) return state.backend();
    if (!recovery) idle();
    const previous = state.backend(null);
    if (recovery && !previous) throw new Error('The original router endpoint is missing; the session cannot be recovered automatically.');
    if (recovery) directory = previous.runtime_directory || runtime();
    const executable = verifyRuntime(directory);
    if (previous && processIdentity(previous.pid) === previous.owner_identity) {
      if (!recovery) throw new Error('CCR is running without its extension. Run dx router stop, then start.');
      await stopOwned(previous);
    }
    const settings = recovery ? { ...previous } : { version: 1, release: RELEASE, management_port: await availablePort(), gateway_port: await availablePort(), core_port: await availablePort(), management_key: state.token(), client_key: state.token() };
    settings.runtime_directory = directory;
    settings.management = `http://127.0.0.1:${settings.management_port}`; settings.gateway = `http://127.0.0.1:${settings.gateway_port}`;
    state.saveBackend(settings);
    const env = nativeEnv('anthropic', state.privateDir(path.join(state.root(), 'unused-auth')));
    Object.assign(env, { DEX_ROUTER_HOME: state.root(), CCR_INTERNAL_HOME_DIR: state.privateDir(path.join(state.root(), 'ccr-home')), CCR_INTERNAL_USER_DATA_DIR: state.privateDir(path.join(state.root(), 'ccr-data')), CCR_WEB_AUTH_TOKEN: settings.management_key, CODEX_HOME: state.privateDir(path.join(state.root(), 'unused-codex')) });
    if (!fs.existsSync(path.join(env.CCR_INTERNAL_HOME_DIR, '.claude-code-router', 'config.sqlite'))) {
      state.write(path.join(env.CCR_INTERNAL_HOME_DIR, '.claude-code-router', 'config.json'), managedConfig({}, settings, state.config(), endpoints, extension));
    }
    // CCR logs can contain provider bodies. Discard them; Dex records redacted events.
    const child = spawn(process.execPath, [executable, 'serve', '--host', '127.0.0.1', '--port', String(settings.management_port), '--no-open'], { detached: true, stdio: 'ignore', env, cwd: state.root() });
    await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    settings.pid = child.pid; settings.owner_identity = processIdentity(child.pid); state.saveBackend(settings); child.unref();
    try {
      let base;
      for (let count = 0; count < 40; count++) {
        if (processIdentity(settings.pid) !== settings.owner_identity) break;
        try { base = await rpc(settings, 'getConfig', [], 500); break; } catch { await delay(100); }
      }
      if (!base) throw new Error('CCR management did not start. Run dx router doctor.');
      await rpc(settings, 'saveConfig', [managedConfig(base, settings, state.config(), endpoints, extension), { applyProfile: false }]);
      // CCR persists transport keys through a separate RPC; saveConfig ignores them.
      await rpc(settings, 'saveApiKeys', [[{ id: 'dex-local', name: 'Dex local transport', key: settings.client_key, createdAt: new Date().toISOString() }]]);
      for (let count = 0; count < 100; count++) { if (await health(true)) return settings; await delay(100); }
      throw new Error('CCR did not load the Dex extension. Run dx router doctor.');
    } catch (error) { await stopOwned(settings); throw error; }
  });
}
async function stopOwned(settings) {
  if (!settings?.pid || !settings.owner_identity || processIdentity(settings.pid) !== settings.owner_identity) return;
  process.kill(settings.pid, 'SIGTERM');
  for (let count = 0; count < 50; count++) { if (processIdentity(settings.pid) !== settings.owner_identity) return; await delay(100); }
  throw new Error('CCR is still stopping. Retry dx router status.');
}
async function stop() { return state.locked('runtime', async () => { idle(); await stopOwned(state.backend(null)); return { stopped: true }; }); }
async function openUI() {
  idle();
  const settings = await start();
  const nonce = state.token();
  const server = http.createServer((request, response) => {
    if (request.method !== 'GET' || request.url !== `/${nonce}`) { response.writeHead(404); response.end(); return; }
    response.writeHead(302, { location: `${settings.management}/?ccr_web_token=${encodeURIComponent(settings.management_key)}`, 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' });
    response.end(); server.close();
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const timer = setTimeout(() => server.close(), 60000); timer.unref(); server.once('close', () => clearTimeout(timer));
  const url = `http://127.0.0.1:${server.address().port}/${nonce}`;
  const child = spawn(process.platform === 'darwin' ? 'open' : 'xdg-open', [url], { stdio: 'ignore' });
  await new Promise((resolve, reject) => {
    child.once('error', () => { server.close(); reject(new Error('No browser opener is available. Use the terminal account and route dashboards.')); });
    child.once('exit', code => { if (code === 0) resolve(); else { server.close(); reject(new Error('Could not open the CCR dashboard.')); } });
  });
}
module.exports = { RELEASE, runtime, availablePort, idle, install, verifyRuntime, rpc, managedConfig, health, start, stop, stopOwned, openUI };
