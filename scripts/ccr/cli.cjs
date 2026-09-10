#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline/promises');
const state = require('./state.cjs');
const policy = require('./policy.cjs');
const adapter = require('./adapter.cjs');
const ipc = require('./ipc.cjs');
const onboarding = require('./onboarding.cjs');
const { launch } = require('./launch.cjs');

const clean = value => String(value ?? '').replace(/[\x00-\x1f\x7f-\x9f]/g, ' ');
const out = value => process.stdout.write(`${clean(value)}\n`);
const info = value => process.stderr.write(`dex: ${clean(value)}\n`);
function parse(args) {
  const result = { positional: [], fallback: [] };
  const values = new Set(['name', 'context', 'session', 'scope', 'phase', 'effort', 'fallback']);
  const switches = new Set(['json', 'yes', 'device', 'watch', 'tools', 'images']);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (!arg.startsWith('--')) { result.positional.push(arg); continue; }
    const key = arg.slice(2);
    if (values.has(key)) {
      const value = args[++index]; if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value.`);
      if (key === 'fallback') result.fallback.push(value); else result[key] = value;
    } else if (switches.has(key)) result[key] = true;
    else throw new Error(`Unknown option: ${arg}`);
  }
  return result;
}
async function question(prompt, fallback) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('This command needs a terminal. Supply the documented explicit arguments for unattended use.');
  const terminal = readline.createInterface({ input: process.stdin, output: process.stdout });
  try { return (await terminal.question(`${prompt}${fallback === undefined ? '' : ` [${fallback}]`}: `)).trim() || fallback; }
  finally { terminal.close(); }
}
async function confirm(prompt, yes) { return yes || /^y(es)?$/i.test(await question(`${prompt} (y/N)`, 'n')); }
function display(value, json) { if (json) process.stdout.write(`${JSON.stringify(value, null, 2)}\n`); else if (typeof value === 'string') out(value); else process.stdout.write(`${JSON.stringify(value, null, 2)}\n`); }
async function configure(change, catalogueChange = false) {
  return state.locked('runtime', () => state.locked('config', () => {
    if (catalogueChange) adapter.idle();
    const config = state.config(); change(config);
    if (config.default_model) policy.contextLimit(config);
    for (const session of state.sessions().filter(require('./service.cjs').active)) policy.route(config, session);
    state.write(state.stateFile('config'), config); return config;
  }));
}
function accountRows(items) {
  return items.map(account => {
    const usage = account.usage;
    const fresh = usage && Date.now() - usage.observed_at < 120000 && !account.usage_error;
    const windows = usage?.windows || [];
    const windowText = window => `${window.name} ${Math.round(window.remaining_ratio * 100)}% left${fresh ? '' : ' (stale)'}${window.resets_at ? `; reset ${new Date(window.resets_at).toLocaleString()}` : ''}`;
    const status = !account.enabled ? 'disabled' : account.status === 'reauth-required' ? 'reauth-required' : account.cooldown_until > Date.now() ? `cooldown until ${new Date(account.cooldown_until).toLocaleTimeString()}` : 'ready';
    return `${account.name.padEnd(22)} ${account.provider.padEnd(10)} ${status}\n  ${windows.length ? windows.map(windowText).join(' | ') : 'Quota unknown; no provider reading available.'}`;
  });
}
async function accounts(options) {
  if (options.watch && !process.stdout.isTTY) throw new Error('--watch needs an interactive terminal. Use --json for scripts.');
  do {
    let items = state.accounts();
    if (await adapter.health()) { try { items = await ipc.call('usage', {}, 30000); } catch { info('Quota refresh unavailable; showing cached readings.'); } }
    if (options.json) display({ version: 1, accounts: items }, true);
    else { if (options.watch) process.stdout.write('\x1b[2J\x1b[H'); out('Dex subscription accounts'); for (const row of accountRows(items)) process.stdout.write(`${row}\n`); if (!items.length) out('No accounts. Run dx account add.'); }
    if (options.watch) await new Promise(resolve => setTimeout(resolve, 30000));
  } while (options.watch);
}
async function addAccount(provider, options, previous) {
  if (!provider) { out('1. Anthropic Claude\n2. OpenAI ChatGPT / Codex'); provider = (await question('Provider', '1')) === '2' ? 'openai' : 'anthropic'; }
  const name = options.name || previous?.name || await question('Account name', `${provider}-${state.accounts().filter(item => item.provider === provider).length + 1}`);
  info(`Opening ${provider} subscription login. Existing accounts stay signed in.`);
  const result = await onboarding.register({ provider, name, device: options.device, reauth: previous?.id, confirm: identity => confirm(`Register ${clean(identity)} as ${clean(name)}?`, options.yes) });
  info(`Added ${result.name}. Credentials are stored ${process.platform === 'darwin' ? 'in macOS Keychain' : 'in an owner-only local file'}.`);
  try {
    const discovered = await onboarding.discover(result);
    if (discovered.length) {
      await state.locked('accounts', () => { const items = state.accounts(); const account = items.find(item => item.id === result.id); if (account) { account.model_ids = discovered.map(model => model.id); state.saveAccounts(items); } });
      await configure(config => { for (const model of discovered) if (!config.models.some(item => item.id === model.id)) config.models.push(model); }, true);
      info(`Discovered ${discovered.length} models. Run dx model list.`);
      if (await adapter.health()) { await adapter.stop(); await adapter.start(); }
    }
  } catch (error) { info(`Account saved. ${error.message}`); }
  return result;
}
async function accountCommand(action, args, options) {
  if (action === 'add') return addAccount(args[0], options);
  if (action === 'list') return accounts(options);
  if (!args[0]) throw new Error(`dx account ${action} requires an account name.`);
  const account = state.getAccount(args[0]);
  if (action === 'show') return account;
  if (action === 'reauth') return addAccount(account.provider, options, account);
  if (action === 'doctor') {
    const { AccountBroker } = require('./accounts.cjs'); await new AccountBroker().access(account); return { account: account.name, credentials: 'renewable', usage: account.usage || null };
  }
  if (action === 'remove' && !await confirm(`Remove ${account.name} and delete its stored login?`, options.yes)) return 'Account retained.';
  return onboarding.changeAccount(action, args[0], args[1]);
}
async function modelCommand(action, args, options) {
  if (action === 'list') return state.config().models;
  if (action === 'current') return ipc.call('route', { action: 'status', session: options.session || process.env.DX_ROUTER_SESSION_ID });
  if (action === 'use') return routeCommand('use', args, options);
  if (action === 'discover') {
    adapter.idle(); const account = state.getAccount(args[0]); const models = await onboarding.discover(account);
    await configure(config => { for (const model of models) { const old = config.models.findIndex(item => item.id === model.id); if (old >= 0) config.models[old] = model; else config.models.push(model); } }, true);
    if (await adapter.health()) { await adapter.stop(); await adapter.start(); } return models;
  }
  if (action !== 'add' || !/^(anthropic|openai)\/[A-Za-z0-9][A-Za-z0-9._:+-]*$/.test(args[0] || '')) throw new Error('Use dx model add <provider/model> --context <tokens> --tools [--images].');
  const context = Number(options.context);
  if (!Number.isSafeInteger(context) || context < 8192 || context > 4000000 || !options.tools) throw new Error('Specify a supported context window (8192–4000000) and confirm --tools support.');
  const model = { id: args[0], upstream_id: args[0].split('/')[1], provider: args[0].split('/')[0], context_window: context, context_source: 'user', capabilities: { tools: true, images: Boolean(options.images) } };
  await configure(config => { config.models = [...config.models.filter(item => item.id !== model.id), model]; }, true);
  if (await adapter.health()) { await adapter.stop(); await adapter.start(); } return model;
}
async function routeCommand(action, args, options) {
  if (action === 'configure') {
    const model = args[0] || await question('Default model (provider/model)');
    return configure(config => {
      policy.model(config, model); for (const fallback of options.fallback) policy.model(config, fallback);
      if (options.effort && !['minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(options.effort)) throw new Error('Unknown reasoning effort.');
      const choice = { model, fallbacks: options.fallback, ...(options.effort ? { effort: options.effort } : {}) };
      if (options.phase !== undefined) {
        const phase = /^\d$/.test(options.phase) ? Number(options.phase) : policy.PHASES.indexOf(options.phase);
        if (phase < 0 || phase > 6) throw new Error('Phase must be 0–6 or a lifecycle phase name.'); config.phases[phase] = choice;
      } else { config.default_model = model; for (let phase = 0; phase <= 6; phase++) config.phases[phase] = choice; }
    });
  }
  if (action === 'policy') return state.config();
  const mapped = { 'pin-account': 'pin', 'unpin-account': 'unpin' }[action] || action;
  return ipc.call('route', { action: mapped === 'use' && args[0] === 'auto' ? 'auto' : mapped, model: args[0], account: args[0], scope: options.scope, session: options.session || process.env.DX_ROUTER_SESSION_ID });
}
async function routerCommand(action, options) {
  if (action === 'install') { await adapter.install(); return `Installed CCR ${adapter.RELEASE}.`; }
  if (action === 'setup') {
    await adapter.install();
    if (!state.accounts().length) await addAccount(undefined, options);
    if (!state.config().models.length) throw new Error('Add a subscription model with dx model add, then run dx router setup again.');
    if (!state.config().default_model) {
      state.config().models.forEach(model => out(model.id));
      await routeCommand('configure', [await question('Default model', state.config().models[0].id)], options);
    }
    await configure(config => { config.enabled = true; }); await adapter.start();
    return 'CCR routing is ready. Select it with dx provider use ccr-subscription. Direct profiles remain available.';
  }
  if (action === 'enable') { await configure(config => { policy.contextLimit(config); config.enabled = true; }); await adapter.start(); return 'CCR routing enabled.'; }
  if (action === 'disable') { await configure(config => { config.enabled = false; }); return 'CCR routing disabled for new sessions. Running sessions can finish. Select dx provider use claude-subscription for direct launches.'; }
  if (action === 'stop') return adapter.stop();
  if (action === 'restart') { await adapter.stop(); await adapter.start(); return 'CCR restarted.'; }
  if (action === 'start') { if (!state.config().enabled) throw new Error('Run dx router setup or enable first.'); await adapter.start(); return 'CCR started.'; }
  if (action === 'update') { adapter.idle(); await adapter.install(); return `Using tested release ${adapter.RELEASE}. CCR upgrades ship with Dex after contract tests pass.`; }
  if (action === 'status' || action === 'doctor') {
    let installed = false; try { adapter.verifyRuntime(); installed = true; } catch { /* Report as a diagnostic. */ }
    const health = await adapter.health();
    return { version: 1, enabled: state.config().enabled, release: adapter.RELEASE, installed, health: health ? 'running' : 'stopped', active_sessions: health?.active_sessions || 0, accounts: state.accounts().length, models: state.config().models.length, credential_store: process.platform === 'darwin' ? 'macOS Keychain' : 'owner-only file' };
  }
  if (action === 'check') {
    if (!state.config().enabled || !state.accounts().some(item => item.enabled)) throw new Error('CCR needs setup and an enabled account. Run dx router setup.');
    policy.contextLimit(state.config()); adapter.verifyRuntime(); return undefined;
  }
  throw new Error(`Unknown router command: ${action}`);
}
async function main(args) {
  const [group, ...rest] = args;
  if (group === 'launch') { process.exitCode = await launch(rest[0] === '--' ? rest.slice(1) : rest); return; }
  const options = parse(rest); const [action, ...values] = options.positional;
  let result;
  if (group === 'accounts') { await accounts(options); return; }
  if (group === 'account') result = await accountCommand(action || 'list', values, options);
  else if (group === 'model') result = await modelCommand(action || 'list', values, options);
  else if (group === 'route') result = await routeCommand(action || 'status', values, options);
  else if (group === 'router') result = await routerCommand(action || 'status', options);
  else throw new Error('Unknown subscription routing command.');
  if (result !== undefined) display(result, options.json);
}
if (require.main === module) {
  process.umask(0o077);
  main(process.argv.slice(2)).catch(error => { info(error.message); process.exitCode = 1; });
}
module.exports = { clean, parse, question, configure, accountRows, accountCommand, modelCommand, routeCommand, routerCommand, main };
