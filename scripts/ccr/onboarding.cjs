'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const state = require('./state.cjs');
const { CredentialStore, AccountBroker, nativeEnv, readNative, authHeaders, keychain } = require('./accounts.cjs');

function accountName(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_. -]{0,59}$/.test(value)) throw new Error('Use an account name of 1–60 letters, numbers, spaces, dots, hyphens or underscores.');
  return value.trim();
}
async function identity(provider, credentials, fetchImpl = fetch) {
  if (provider === 'openai') {
    if (!credentials.account_id || !credentials.subject) throw new Error('The native login did not identify a ChatGPT subscription account.');
    return { fingerprint: state.hash(`openai:${credentials.account_id}:${credentials.subject}`), label: credentials.email || credentials.account_id };
  }
  const response = await fetchImpl('https://api.anthropic.com/api/oauth/profile', { headers: authHeaders(provider, credentials), redirect: 'error', signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error('Claude could not confirm this subscription identity. Retry the login.');
  const data = await response.json();
  const id = data.account?.uuid || data.account?.id; const org = data.organization?.uuid || data.organization?.id;
  if (!id || !org) throw new Error('Claude returned an unrecognised subscription identity.');
  return { fingerprint: state.hash(`anthropic:${org}:${id}`), label: data.account.email_address || data.account.email || id };
}
function loginCommand(provider, device = false) {
  if (provider === 'anthropic') {
    if (device) throw new Error('Claude login requires its native browser flow; --device is available for OpenAI.');
    return ['claude', ['auth', 'login', '--claudeai']];
  }
  if (provider !== 'openai') throw new Error('Provider must be anthropic or openai.');
  return ['bash', [path.resolve(__dirname, '../../bin/dxcodex.sh'), 'auth-login', ...(device ? ['--device-auth'] : [])]];
}
async function nativeLogin(provider, directory, device) {
  const [command, args] = loginCommand(provider, device);
  const env = nativeEnv(provider, directory);
  env.DEX_DIR = path.resolve(__dirname, '../..'); env.DEX_ROUTER_AUTH_HOME = directory; env.DEX_ROUTER_HOME = state.root();
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, stdio: 'inherit' });
    child.once('error', () => reject(new Error(`The ${provider === 'anthropic' ? 'Claude Code' : 'Codex'} login helper is missing. Install its official CLI, then retry dx account add.`)));
    child.once('exit', code => code === 0 ? resolve() : reject(new Error('Login was cancelled or failed. Your existing accounts are unchanged.')));
  });
}
async function register({ provider, name, device = false, reauth, confirm = async () => true, login = nativeLogin, resolveIdentity = identity, store = new CredentialStore() }) {
  loginCommand(provider, device); name = accountName(name);
  const previous = reauth ? state.getAccount(reauth) : null;
  if (previous && previous.provider !== provider) throw new Error('Reauthentication must use the existing provider.');
  const id = previous?.id || `acc-${state.token().slice(0, 18)}`;
  const directory = state.privateDir(path.join(state.root(), 'logins', `${id}-${state.token().slice(0, 8)}`));
  let native;
  try {
    await login(provider, directory, device);
    native = readNative(provider, directory);
    const who = await resolveIdentity(provider, native.tokens);
    if (previous && previous.fingerprint !== who.fingerprint) throw new Error('This is a different account. Reauthenticate the original identity or add it as a new account.');
    const duplicate = state.accounts().find(item => item.fingerprint === who.fingerprint && item.id !== id);
    if (duplicate) throw new Error(`This account is already registered as ${duplicate.name}.`);
    if (!await confirm(who.label)) throw new Error('Account registration cancelled.');
    return await state.locked('accounts', () => state.locked(`credential-${id}`, () => {
      const items = state.accounts();
      if (items.some(item => item.id !== id && (item.fingerprint === who.fingerprint || item.name === name))) throw new Error('That account or name is already registered.');
      if (previous && !items.some(item => item.id === id)) throw new Error('The account was removed during login. Add it again.');
      const account = { id, name, provider, enabled: true, status: 'ready', fingerprint: who.fingerprint, identity: who.label, created_at: previous?.created_at || Date.now(), authenticated_at: Date.now() };
      const oldCredentials = store.get(id);
      store.set(id, native.tokens);
      try { state.saveAccounts([...items.filter(item => item.id !== id), account]); }
      catch (error) { if (oldCredentials) store.set(id, oldCredentials); else store.delete(id); throw error; }
      return account;
    }));
  } finally {
    // Only the temporary native login belongs to this operation.
    if (process.platform === 'darwin' && provider === 'anthropic') {
      const service = native?.native_service || `Claude Code-credentials-${state.hash(directory.normalize('NFC')).slice(0, 8)}`;
      keychain('delete', service, process.env.USER || os.userInfo().username);
    }
    fs.rmSync(directory, { recursive: true, force: true });
  }
}
async function changeAccount(action, selector, value, store = new CredentialStore()) {
  return state.locked('accounts', async () => {
    const items = state.accounts(); const account = state.getAccount(selector, items);
    if (action === 'rename') {
      const name = accountName(value); if (items.some(item => item.id !== account.id && item.name === name)) throw new Error('That name is already in use.'); account.name = name;
    } else if (action === 'enable' || action === 'disable') account.enabled = action === 'enable';
    else if (action === 'remove') {
      // Removing membership first prevents new requests from selecting this identity.
      state.saveAccounts(items.filter(item => item.id !== account.id));
      try { await state.locked(`credential-${account.id}`, () => store.delete(account.id)); }
      catch (error) { account.enabled = false; state.saveAccounts(items); throw error; }
      return { removed: account.name };
    } else throw new Error('Unknown account operation.');
    state.saveAccounts(items); return account;
  });
}
function catalogue(provider, payload) {
  const entries = payload.data || payload.models || [];
  if (!Array.isArray(entries)) throw new Error('The provider returned an unrecognised model catalogue.');
  return entries.map(item => {
    const name = item.id || item.slug;
    if (typeof name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:+-]*$/.test(name)) return null;
    const context = item.max_input_tokens || item.context_window || item.context_length;
    return { id: `${provider}/${name}`, upstream_id: name, provider, display_name: item.display_name || name,
      context_window: Number.isInteger(context) && context >= 8192 ? context : 64000,
      context_source: Number.isInteger(context) ? 'provider' : 'conservative-default',
      capabilities: { tools: true, images: provider === 'anthropic' || item.input_modalities?.includes('image') === true },
      efforts: item.supported_reasoning_levels?.map(level => level.reasoning_effort || level.effort).filter(Boolean) || [], observed_at: Date.now() };
  }).filter(Boolean);
}
async function discover(account, broker = new AccountBroker()) {
  const credentials = await broker.access(account);
  const endpoint = account.provider === 'anthropic' ? 'https://api.anthropic.com/v1/models' : 'https://chatgpt.com/backend-api/codex/models?client_version=0.114.0';
  const response = await fetch(endpoint, { headers: { ...authHeaders(account.provider, credentials), 'anthropic-version': '2023-06-01' }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error('Model discovery is unavailable. Use dx model add with a model available to this subscription.');
  return catalogue(account.provider, await response.json());
}
module.exports = { accountName, identity, loginCommand, nativeLogin, register, changeAccount, catalogue, discover };
