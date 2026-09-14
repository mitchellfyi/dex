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
const { table, liveScreen } = require('./output.cjs');

const clean = value => String(value ?? '').replace(/[\x00-\x1f\x7f-\x9f]/g, ' ');
const out = value => process.stdout.write(`${clean(value)}\n`);
const info = value => process.stderr.write(`dex: ${clean(value)}\n`);
function parse(args) {
  const result = { positional: [], fallback: [] };
  const values = new Set(['name', 'context', 'session', 'scope', 'phase', 'client', 'effort', 'fallback']);
  const switches = new Set(['json', 'yes', 'device', 'watch', 'tools', 'images']);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (!arg.startsWith('--')) { result.positional.push(arg); continue; }
    const key = arg === '--live' ? 'watch' : arg.slice(2);
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
const showTable = (headers, rows, options) => process.stdout.write(table(headers, rows, options));
const details = rows => showTable(['Field', 'Value'], rows);
const capability = value => typeof value === 'boolean' ? value ? 'yes' : 'no' : 'unknown';
function render(group, action, value, options) {
  if (options.json || typeof value === 'string') { display(value, options.json); return; }
  if (value?.session && value.route) {
    const session = value.session; const account = state.accounts().find(item => item.id === session.current_account);
    const rows = [
      ['Session', session.id], ['Phase', `${value.route.phase} (${policy.PHASES[value.route.phase] || 'lifecycle complete'})`],
      ['Policy', session.override ? `${session.override.scope} override` : 'configured phases'],
      ['Selected', value.route.models.map(model => model.id).join(' -> ')],
      ['Last used', `${session.current_model || 'pending'}${account ? ` / ${account.name}` : ''}`]
    ];
    if (session.pinned_account) rows.push(['Pinned', state.getAccount(session.pinned_account).name]);
    if (session.paused_reason) rows.push(['Paused', `${session.paused_reason}; inspect dx accounts`]);
    details(rows);
    return;
  }
  if (group === 'model' && (Array.isArray(value) || value?.id)) {
    const models = Array.isArray(value) ? value : [value];
    if (!models.length) out('No models registered. Add an account, or run dx model add.');
    showTable(['Model', 'Context', 'Source', 'Tools', 'Images'], models.map(model => [
      model.id, model.context_window?.toLocaleString('en-US') || 'unknown', model.context_source || 'configured',
      capability(model.capabilities?.tools), capability(model.capabilities?.images)
    ]), { rightAlign: [1] });
    return;
  }
  if ((group === 'route' && ['configure', 'policy'].includes(action)) && value?.phases) {
    out(`Default model: ${value.default_model || 'not selected'}`);
    showTable(['Phase', 'Model', 'Fallbacks (in order)', 'Effort'], policy.PHASES.map((name, phase) => {
      const route = value.phases[phase] || { model: value.default_model };
      return [`${phase} ${name}`, route.model || 'not selected', route.fallbacks?.join(' -> ') || '-', route.effort || 'default'];
    }));
    const clients = Object.entries(value.client_routes || {});
    if (clients.length) {
      out('Native client routes:');
      showTable(['Client', 'Model', 'Fallbacks (in order)', 'Effort'], clients.map(([client, route]) => [
        client, route.model, route.fallbacks?.join(' -> ') || '-', route.effort || 'default'
      ]));
    }
    return;
  }
  if (group === 'account' && value?.name) {
    details([['Account', value.name], ['Rank', value.rank || 'automatic'], ['Identity', value.identity || value.id], ['ID', value.id]]);
    showAccounts([value]);
    return;
  }
  if (group === 'account' && value?.credentials) {
    details([['Account', value.account], ['Credentials', value.credentials]]);
    showAccounts([{ ...state.getAccount(value.account), usage: value.usage }]);
    return;
  }
  if (group === 'router' && value?.release) {
    details([
      ['CCR version', value.release], ['Runtime', value.health], ['Installed', value.installed ? 'yes' : 'no'],
      ['Routing', value.enabled ? 'enabled' : 'disabled'], ['Accounts', value.accounts],
      ['Models', value.models], ['Active sessions', value.active_sessions], ['Credentials', value.credential_store]
    ]);
    if (!value.installed) out('Run dx router setup to install the optional runtime.');
    return;
  }
  display(value, false);
}
async function configure(change, catalogueChange = false) {
  return state.locked('runtime', () => state.locked('config', () => {
    if (catalogueChange) adapter.idle();
    const config = state.config(); change(config);
    if (config.default_model) policy.contextLimit(config);
    for (const session of state.sessions().filter(require('./service.cjs').active)) policy.route(config, session);
    state.write(state.stateFile('config'), config); return config;
  }));
}
function resetIn(timestamp, now) {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return 'unknown';
  if (timestamp <= now) return 'due';
  const minutes = Math.ceil((timestamp - now) / 60000);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h ${minutes % 60}m` : `${Math.floor(hours / 24)}d ${hours % 24}h`;
}
function accountWindows(items) {
  const names = new Set(items.flatMap(account => (account.usage?.windows || []).map(window => window.name)));
  return ['5h', 'weekly', ...[...names].filter(name => name !== '5h' && name !== 'weekly').sort()];
}
function accountModels(account, config, now) {
  const ids = [...new Set([config.default_model, ...Object.values(config.phases).flatMap(route => [route.model, ...(route.fallbacks || [])]),
    ...Object.values(config.client_routes || {}).flatMap(route => [route.model, ...(route.fallbacks || [])]),
    ...Object.entries(account.model_cooldowns || {}).filter(([, until]) => until > now).map(([id]) => id)])];
  const models = ids.map(id => config.models.find(model => model.id === id)).filter(model => model?.provider === account.provider);
  return models.length ? models : [null];
}
function accountRows(items, now = Date.now(), windowNames = accountWindows(items), config = state.config()) {
  return items.flatMap(account => accountModels(account, config, now).map(model => {
    const usage = account.usage;
    const fresh = usage && now - usage.observed_at < 120000 && !account.usage_error;
    const windows = (usage?.windows || []).filter(window => !model || !window.model_pool || model.id.includes(window.model_pool));
    const exhausted = fresh && windows.some(window => !window.model_pool && window.remaining_ratio === 0 && (!window.resets_at || window.resets_at > now));
    const reasons = { disabled: 'disabled', 'reauth-required': 'reauth-required', 'model-unavailable': 'not available',
      temporary: 'temporary provider error', 'connection-failed': 'connection failed', 'refresh-unavailable': 'login refresh unavailable', 'rate-limit': 'rate limited' };
    const limits = Object.entries(account.model_cooldowns || {}).filter(([, until]) => until > now)
      .map(([model, until]) => `${model.split('/').pop()} ${reasons[account.model_cooldown_reasons?.[model]] || 'rate limited'} (${policy.retryIn(until, now)})`);
    const reason = reasons[account.cooldown_reason] || 'cooldown';
    const summary = !account.enabled ? 'disabled' : account.status === 'reauth-required' ? 'reauth-required'
      : account.cooldown_until > now ? `${reason} (${policy.retryIn(account.cooldown_until, now)})`
        : exhausted ? 'quota exhausted' : limits.join('; ') || 'ready';
    const status = model ? policy.blockers(account, model, now).map(problem => {
      const label = problem.reason === 'quota-exhausted' ? `${problem.window} quota exhausted` : reasons[problem.reason] || 'cooldown';
      return `${label}${problem.until > now && problem.reason !== 'quota-exhausted' ? ` (${policy.retryIn(problem.until, now)})` : ''}`;
    }).join('; ') || 'ready' : summary;
    return [account.name, account.rank || '-', account.provider, model ? (model.display_name || model.id.split('/')[1]).replace(/^Claude /, '') : '-', status, ...windowNames.flatMap(name => {
      const window = windows.find(item => item.name === name);
      if (!window) return usage?.windows?.length ? ['-', '-'] : ['unknown', 'unknown'];
      return [`${Math.round(window.remaining_ratio * 100)}%${fresh ? '' : ' (stale)'}`, resetIn(window.resets_at, now)];
    })];
  }));
}
function accountTable(items) {
  const windows = accountWindows(items);
  const headers = ['Account', 'Rank', 'Provider', 'Model', 'Status', ...windows.flatMap(name => {
    const label = name[0].toUpperCase() + name.slice(1).replaceAll('-', ' ');
    return [`${label} left`, 'Reset in'];
  })];
  return table(headers, accountRows(items, Date.now(), windows), { rightAlign: [1, ...windows.map((_, index) => 5 + index * 2)] });
}
function showAccounts(items) {
  process.stdout.write(accountTable(items));
}
function accountsFrame(items, live, note = '') {
  const rows = accountTable(items) || 'No accounts. Run dx account add.\n';
  const footer = live
    ? `View updated at ${new Date().toLocaleTimeString()}\nLive: every 30s. Ctrl+C to exit.`
    : 'Tip: use dx accounts --live for updates.';
  return `Dex subscription accounts\n${rows}\nModels follow configured routes. Shared quota is repeated across model rows.\n${note ? `${note}\n` : ''}${footer}\n`;
}
async function accounts(options) {
  if (options.watch && options.json) throw new Error('--live/--watch cannot be combined with --json. Use dx accounts --json for a single snapshot.');
  if (options.watch && !process.stdout.isTTY) throw new Error('--live/--watch needs an interactive terminal. Use --json for scripts.');
  const screen = options.watch ? liveScreen() : null;
  let first = true;
  try {
    do {
      let items = state.accounts();
      let note = '';
      if (screen && first) screen.render(accountsFrame(items, true, 'Refreshing usage...'), 3);
      first = false;
      if (await adapter.health()) {
        try { items = await ipc.call('usage', {}, 30000); }
        catch {
          note = 'Quota refresh unavailable.\nShowing cached readings.';
          if (!screen) info('Quota refresh unavailable; showing cached readings.');
        }
      } else if (screen) note = 'CCR is stopped; showing cached readings.\nRun dx router start to refresh usage.';
      if (options.json) display({ version: 1, accounts: items }, true);
      else if (screen) screen.render(accountsFrame(items, true, note), note ? 4 : 2);
      else process.stdout.write(accountsFrame(items, false));
      if (screen) await new Promise(resolve => setTimeout(resolve, 30000));
    } while (screen);
  } finally { screen?.close(); }
}
async function addAccount(provider, options, previous) {
  if (!provider) { out('1. Anthropic Claude'); out('2. OpenAI ChatGPT / Codex'); const selected = await question('Provider', '1'); if (!['1', '2'].includes(selected)) throw new Error('Choose 1 or 2.'); provider = selected === '2' ? 'openai' : 'anthropic'; }
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
    await state.locked('accounts', () => {
      const items = state.accounts(); const current = state.getAccount(account.id, items);
      current.model_ids = models.map(model => model.id); state.saveAccounts(items);
    });
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
      const fallbacks = options.fallback || [];
      policy.model(config, model); for (const fallback of fallbacks) policy.model(config, fallback);
      if (options.effort && !['minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(options.effort)) throw new Error('Unknown reasoning effort.');
      if (options.client && options.phase !== undefined) throw new Error('Choose either --client or --phase, not both.');
      if (options.client && !['claude', 'codex'].includes(options.client)) throw new Error('Client must be claude or codex.');
      const choice = { model, fallbacks, ...(options.effort ? { effort: options.effort } : {}) };
      if (options.client) {
        config.client_routes ||= {}; config.client_routes[options.client] = choice;
      } else if (options.phase !== undefined) {
        const phase = /^\d$/.test(options.phase) ? Number(options.phase) : policy.PHASES.indexOf(options.phase);
        if (phase < 0 || phase > 6) throw new Error('Phase must be 0–6 or a lifecycle phase name.'); config.phases[phase] = choice;
      } else { config.default_model = model; for (let phase = 0; phase <= 6; phase++) config.phases[phase] = choice; }
    });
  }
  if (action === 'policy') return state.config();
  const mapped = { 'pin-account': 'pin', 'unpin-account': 'unpin' }[action] || action;
  return ipc.call('route', { action: mapped === 'use' && args[0] === 'auto' ? 'auto' : mapped, model: args[0], account: args[0], scope: options.scope, session: options.session || process.env.DX_ROUTER_SESSION_ID });
}
async function routerCommand(action, options, args = []) {
  if (action === 'native') return require('./native.cjs').command(args[0] || 'status', options);
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
  if (action === 'ui') { await adapter.openUI(); return 'Opened the private CCR dashboard. Dex account and routing settings are managed by dx commands.'; }
  if (action === 'restart') { await adapter.stop(); await adapter.start(); return 'CCR restarted.'; }
  if (action === 'start') { if (!state.config().enabled) throw new Error('Run dx router setup or enable first.'); await adapter.start(); return 'CCR started.'; }
  if (action === 'update') { adapter.idle(); await adapter.install(); return `Using tested release ${adapter.RELEASE}. CCR upgrades ship with Dex after contract tests pass.`; }
  if (action === 'status' || action === 'doctor') {
    let installed = false; try { adapter.verifyRuntime(); installed = true; } catch { /* Report as a diagnostic. */ }
    const health = await adapter.health();
    const sessions = health ? await ipc.call('health', { sessions: true }) : null;
    return { version: 1, enabled: state.config().enabled, release: adapter.RELEASE, installed, health: health ? 'running' : 'stopped', active_sessions: sessions?.active_sessions || 0, accounts: state.accounts().length, models: state.config().models.length, credential_store: process.platform === 'darwin' ? 'macOS Keychain' : 'owner-only file' };
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
  if (options.watch && !(group === 'accounts' || (group === 'account' && (!action || action === 'list')))) {
    throw new Error('--live/--watch is only available with dx accounts or dx account list.');
  }
  if (options.json && ((group === 'router' && action === 'setup')
    || (group === 'account' && ((action === 'add' && (!values[0] || !options.name || !options.yes))
      || (['remove', 'reauth'].includes(action) && !options.yes))))) {
    throw new Error('--json requires explicit account choices and --yes; run router setup interactively without --json.');
  }
  const arity = group === 'accounts' ? [0, 0] : group === 'router' ? (action === 'native' ? [0, 1] : [0, 0])
    : group === 'account' ? (['rename', 'rank'].includes(action) ? [2, 2] : ['list', undefined].includes(action) ? [0, 0] : action === 'add' ? [0, 1] : [1, 1])
      : group === 'model' ? (['list', 'current', undefined].includes(action) ? [0, 0] : [1, 1])
        : group === 'route' ? (['status', 'policy', 'unpin-account', undefined].includes(action) ? [0, 0] : [1, 1]) : [0, 0];
  const provided = group === 'accounts' ? options.positional.length : values.length;
  if (provided < arity[0] || provided > arity[1]) throw new Error(`Unexpected arguments for dx ${group}${action ? ` ${action}` : ''}. Run dx ${group} --help.`);
  let result;
  if (group === 'accounts') { await accounts(options); return; }
  if (group === 'account') result = await accountCommand(action || 'list', values, options);
  else if (group === 'model') result = await modelCommand(action || 'list', values, options);
  else if (group === 'route') result = await routeCommand(action || 'status', values, options);
  else if (group === 'router') result = await routerCommand(action || 'status', options, values);
  else throw new Error('Unknown subscription routing command.');
  if (result !== undefined) render(group, action || (group === 'model' ? 'list' : 'status'), result, options);
}
if (require.main === module) {
  process.umask(0o077);
  main(process.argv.slice(2)).catch(error => { info(error.message); process.exitCode = 1; });
}
module.exports = { clean, parse, question, configure, accountRows, accountCommand, modelCommand, routeCommand, routerCommand, main };
