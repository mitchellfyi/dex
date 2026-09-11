'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const state = require('./state.cjs');

// Public native-client identifiers; these are not client secrets.
const PROVIDERS = {
  anthropic: { token: 'https://platform.claude.com/v1/oauth/token', client: '9d1c250a-e61b-44d9-88ed-5944d1962f5e', usage: 'https://api.anthropic.com/api/oauth/usage' },
  openai: { token: 'https://auth.openai.com/oauth/token', client: 'app_EMoamEEZ73f0CkXaXp7hrann', usage: 'https://chatgpt.com/backend-api/wham/usage' }
};

function keychain(operation, service, account, value) {
  const result = spawnSync('python3', [path.join(__dirname, 'native.py')], {
    input: JSON.stringify({ operation, service, account, value }), encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024
  });
  if (result.status !== 0) throw new Error('Credential store access failed. Unlock or allow access to Keychain and retry.');
  return JSON.parse(result.stdout);
}

class CredentialStore {
  constructor(platform = process.platform) { this.platform = platform; }
  file(id) { return path.join(state.root(), 'credentials', `${state.checkedId(id)}.json`); }
  get(id) { return this.platform === 'darwin' ? keychain('read', 'Dex CCR OAuth', state.checkedId(id)) : state.read(this.file(id), null); }
  set(id, value) { if (this.platform === 'darwin') keychain('write', 'Dex CCR OAuth', state.checkedId(id), value); else state.write(this.file(id), value); }
  delete(id) { if (this.platform === 'darwin') keychain('delete', 'Dex CCR OAuth', state.checkedId(id)); else fs.rmSync(this.file(id), { force: true }); }
}

function jwt(value) {
  try { return JSON.parse(Buffer.from(value.split('.')[1], 'base64url').toString()); } catch { return {}; }
}

function normalizeTokens(provider, raw) {
  const tokens = provider === 'anthropic' ? raw?.claudeAiOauth || raw : raw?.tokens || raw;
  if (!tokens || typeof tokens !== 'object') throw new Error('No subscription OAuth credentials were returned.');
  const access = tokens.accessToken || tokens.access_token;
  const refresh = tokens.refreshToken || tokens.refresh_token;
  if (typeof access !== 'string' || !access || typeof refresh !== 'string' || !refresh) throw new Error('A renewable subscription OAuth login is required. API keys are not supported.');
  const claims = jwt(tokens.id_token || access);
  const expiry = Number(tokens.expiresAt || tokens.expires_at || jwt(access).exp * 1000);
  return {
    access_token: access, refresh_token: refresh,
    expires_at: Number.isFinite(expiry) && expiry > 0 ? (expiry < 100000000000 ? expiry * 1000 : expiry) : Date.now() + 3600000,
    account_id: tokens.account_id || claims['https://api.openai.com/auth']?.chatgpt_account_id,
    subject: claims.sub,
    email: claims.email || claims['https://api.openai.com/profile']?.email,
    scope: Array.isArray(tokens.scopes) ? tokens.scopes.join(' ') : tokens.scope
  };
}

function nativeEnv(provider, directory) {
  const env = {};
  for (const key of ['HOME', 'PATH', 'USER', 'LOGNAME', 'SHELL', 'TERM', 'LANG', 'LC_ALL', 'TMPDIR', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS', 'SYSTEMROOT']) {
    if (process.env[key]) env[key] = process.env[key];
  }
  if (provider === 'anthropic') env.CLAUDE_CONFIG_DIR = directory;
  else env.CODEX_HOME = directory;
  return env;
}

function readNative(provider, directory) {
  if (provider === 'anthropic' && process.platform === 'darwin') {
    const service = `Claude Code-credentials-${state.hash(directory.normalize('NFC')).slice(0, 8)}`;
    const raw = keychain('read', service, process.env.USER || os.userInfo().username);
    if (raw) return { tokens: normalizeTokens(provider, raw), native_service: service };
  }
  const file = path.join(directory, provider === 'anthropic' ? '.credentials.json' : 'auth.json');
  return { tokens: normalizeTokens(provider, state.read(file)), native_file: file };
}

function normalizeUsage(provider, data, now = Date.now()) {
  const windows = [];
  const add = (name, raw, used, reset, modelPool) => {
    if (!raw || !Number.isFinite(used) || used < 0 || used > 100) return;
    const parsedReset = typeof reset === 'number' ? reset * 1000 : Date.parse(reset);
    windows.push({ name, remaining_ratio: (100 - used) / 100, resets_at: Number.isFinite(parsedReset) ? parsedReset : null, ...(modelPool ? { model_pool: modelPool } : {}) });
  };
  if (provider === 'anthropic') {
    for (const [field, name, pool] of [['five_hour', '5h'], ['seven_day', 'weekly'], ['seven_day_opus', 'weekly-opus', 'opus'], ['seven_day_sonnet', 'weekly-sonnet', 'sonnet']]) {
      add(name, data[field], data[field]?.utilization, data[field]?.resets_at, pool);
    }
  } else {
    for (const [field, name] of [['primary_window', 'session'], ['secondary_window', 'weekly']]) {
      const raw = data.rate_limit?.[field];
      const period = ({ 18000: '5h', 86400: 'daily', 604800: 'weekly' })[raw?.limit_window_seconds] || name;
      add(period, raw, raw?.used_percent, raw?.reset_at);
    }
  }
  return { observed_at: now, source: 'provider', confidence: windows.length ? 'provider-derived' : 'unknown', windows };
}

class AccountBroker {
  constructor({ store = new CredentialStore(), fetchImpl = fetch, now = Date.now } = {}) {
    this.store = store; this.fetch = fetchImpl; this.now = now; this.refreshes = new Map(); this.usageRequests = new Map();
  }
  async access(account, force = false) {
    if (this.refreshes.has(account.id)) return this.refreshes.get(account.id);
    const operation = state.locked(`credential-${state.checkedId(account.id)}`, async () => {
      let credentials = this.store.get(account.id);
      if (!credentials) { const error = new Error('Account credentials are missing. Run dx account reauth.'); error.reauth = true; throw error; }
      if (!force && credentials.expires_at > this.now() + 60000) return credentials;
      const provider = PROVIDERS[account.provider];
      if (!provider) throw new Error('Unsupported OAuth provider.');
      const response = await this.fetch(provider.token, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20000),
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ grant_type: 'refresh_token', client_id: provider.client, refresh_token: credentials.refresh_token })
      });
      if (!response.ok) {
        const error = new Error(response.status === 400 || response.status === 401 ? 'Account login expired. Run dx account reauth.' : 'Provider token refresh is temporarily unavailable.');
        error.reauth = response.status === 400 || response.status === 401;
        throw error;
      }
      const result = await response.json();
      if (typeof result.access_token !== 'string' || !result.access_token) throw new Error('Provider returned an invalid OAuth refresh response.');
      credentials = { ...credentials, access_token: result.access_token, refresh_token: result.refresh_token || credentials.refresh_token, expires_at: this.now() + (Number(result.expires_in) || 3600) * 1000 };
      this.store.set(account.id, credentials);
      return credentials;
    });
    this.refreshes.set(account.id, operation);
    try { return await operation; } finally { this.refreshes.delete(account.id); }
  }
  async usage(account) {
    if (account.usage && this.now() - account.usage.observed_at < 30000) return account.usage;
    if (this.usageRequests.has(account.id)) return this.usageRequests.get(account.id);
    const operation = (async () => {
      let credentials = await this.access(account);
      const request = () => this.fetch(PROVIDERS[account.provider].usage, {
        headers: authHeaders(account.provider, credentials), redirect: 'error', signal: AbortSignal.timeout(15000)
      });
      let response = await request();
      if (response.status === 401) { await response.body?.cancel(); credentials = await this.access(account, true); response = await request(); }
      if (!response.ok) throw new Error('Quota information is temporarily unavailable.');
      return normalizeUsage(account.provider, await response.json(), this.now());
    })();
    this.usageRequests.set(account.id, operation);
    try { return await operation; } finally { this.usageRequests.delete(account.id); }
  }
}

function authHeaders(provider, credentials) {
  const headers = { authorization: `Bearer ${credentials.access_token}` };
  if (provider === 'anthropic') headers['anthropic-beta'] = 'oauth-2025-04-20';
  else if (credentials.account_id) headers['ChatGPT-Account-ID'] = credentials.account_id;
  return headers;
}

module.exports = { CredentialStore, AccountBroker, PROVIDERS, keychain, jwt, normalizeTokens, nativeEnv, readNative, normalizeUsage, authHeaders };
