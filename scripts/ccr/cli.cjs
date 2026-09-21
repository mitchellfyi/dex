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
const { PROVIDERS, providerKind, periodLength, NAMED_PERIOD_MS } = require('./accounts.cjs');

const clean = value => String(value ?? '').replace(/[\x00-\x1f\x7f-\x9f]/g, ' ');
const out = value => process.stdout.write(`${clean(value)}\n`);
const info = value => process.stderr.write(`dex: ${clean(value)}\n`);
function parse(args) {
  const result = { positional: [], fallback: [], include: [] };
  const values = new Set(['name', 'context', 'max-context', 'upstream', 'price-in', 'price-out', 'price-cached', 'session', 'scope', 'phase', 'client', 'effort', 'fallback', 'transcript', 'include', 'builtin-tools']);
  const switches = new Set(['json', 'yes', 'device', 'watch', 'tools', 'images']);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (!arg.startsWith('--')) { result.positional.push(arg); continue; }
    const key = arg === '--live' ? 'watch' : arg.slice(2);
    if (values.has(key)) {
      const value = args[++index]; if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value.`);
      if (key === 'fallback' || key === 'include') result[key].push(value); else result[key] = value;
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
  if (group === 'context' && value.configured_budget) {
    details([['Session', value.session || 'configuration'], ['Configured context', value.configured_budget], ['Launch context', value.launch_budget || 'no session selected'],
      ['Actual model', value.current_model || 'not recorded'], ['New launch needed', value.restart_required ? 'yes' : 'no']]);
    showTable(['Model', 'Default', 'Maximum', 'Source'], value.models.map(model => [model.id, model.default, model.maximum, model.source]), { rightAlign: [1, 2] });
    if (value.last_request) details(Object.entries(value.last_request).map(([name, item]) =>
      [name, name === 'cost_usd' && item === null ? 'unknown (model has no recorded price)' : item]));
    if (value.mcp_scope) details([['Selected MCPs', value.mcp_scope.selected.join(', ') || 'none'], ['Omitted MCPs', value.mcp_scope.omitted.join(', ') || 'none'], ['Unset MCP variables', value.mcp_scope.missing_env.join(', ') || 'none']]);
    if (value.transcript) {
      const trace = value.transcript;
      details([['Tools in snapshot', trace.tool_count], ['Tool schema bytes', trace.tool_schema_bytes], ['Restored skill characters', trace.restored_skill_characters],
        ['Restored instruction characters', trace.restored_instruction_characters], ['Thrashing recorded', trace.thrashing ? 'yes' : 'no']]);
      showTable(['Compacted at', 'Before', 'Summary/retained', 'Next actual input'], trace.compactions.slice(-6).map(item => [item.timestamp || '-', item.pre_tokens ?? '-', item.post_tokens ?? '-', item.next_input_tokens ?? '-']), { rightAlign: [1, 2, 3] });
    }
    if (value.transcript_error) out(value.transcript_error);
    for (const advice of value.advice) out(advice);
    return;
  }
  if (value?.session && value.route) {
    const session = value.session; const account = state.accounts().find(item => item.id === session.current_account);
    const rows = [
      ['Session', session.id], ['Phase', `${value.route.phase} (${policy.PHASES[value.route.phase] || 'lifecycle complete'})`],
      ['Policy', session.override ? `${session.override.scope} override` : 'configured phases'],
      ['Selected', value.route.models.map(model => model.id).join(' -> ')],
      ['Last used', `${session.current_model || 'pending'}${account ? ` / ${account.name}` : ''}`]
    ];
    if (session.pinned_account) rows.push(['Pinned', state.getAccount(session.pinned_account).name]);
    if (session.last_rejection) rows.push(['Rejected', `${session.last_rejection.model} (HTTP ${session.last_rejection.status})`]);
    if (session.paused_reason) rows.push(['Paused', `${session.paused_reason}; inspect dx accounts`]);
    details(rows);
    return;
  }
  if (group === 'model' && (Array.isArray(value) || value?.id)) {
    const models = Array.isArray(value) ? value : [value];
    if (!models.length) out('No models registered. Add an account, or run dx model add.');
    showTable(['Model', 'Context default', 'Context max', 'Source', 'Tools', 'Images'], models.map(model => [
      model.id, model.context_window?.toLocaleString('en-US') || 'unknown', policy.modelCapacity(model)?.toLocaleString('en-US') || 'unknown', model.context_source || 'configured',
      capability(model.capabilities?.tools), capability(model.capabilities?.images)
    ]), { rightAlign: [1, 2] });
    return;
  }
  if ((group === 'route' && ['configure', 'policy'].includes(action)) && value?.phases) {
    out(`Default model: ${value.default_model || 'not selected'}`);
    if (value.default_model) out(`Operating context budget: ${policy.contextLimit(value)} tokens (running clients retain their launch budget).`);
    showTable(['Phase', 'Model', 'Fallbacks (in order)', 'Effort'], policy.PHASES.map((name, phase) => {
      const route = value.phases[phase] || { model: value.default_model };
      // A stored profile shows what it currently resolves to, not its name:
      // the name lives in the profile table, and a stale one must be visible here.
      const show = id => policy.PROFILE.test(id || '') ? `${id} (${policy.resolveProfiles(structuredClone(value), [id])[0]})` : id;
      return [`${phase} ${name}`, route.model ? show(route.model) : 'not selected',
        route.fallbacks?.length ? route.fallbacks.map(show).join(' -> ') : '-', route.effort || 'default'];
    }));
    out('Client routes through CCR (used when the client is connected to the router):');
    showTable(['Client', 'Source', 'Model', 'Fallbacks (in order)', 'Effort'], ['claude', 'codex'].map(client => {
      // What this client offers in its own picker. Its automatic option is the
      // phase route, shown above, so a client route no longer narrows it.
      const own = policy.clientModels(value, client);
      const automatic = value.phases[0]?.model || value.phases.setup?.model || value.default_model;
      const inherited = own || !automatic ? null : policy.route(value, {});
      const models = own?.models || inherited?.models || [];
      return [client, own ? 'configured' : 'inherited from setup', models[0]?.id || 'not selected',
        models.slice(1).map(model => model.id).join(' -> ') || '-', (own?.effort ?? inherited?.effort) || 'default'];
    }));
    out(`Plain CLI routing: ${value.native?.enabled ? 'through CCR; disable with dx router native disable' : 'native configuration (CCR off)'}.`);
    return;
  }
  if (group === 'account' && value?.name) {
    details([['Account', value.name], ['Rank', value.rank || 'automatic'], ['Identity', value.identity || value.id], ['ID', value.id]]);
    showAccounts([value]);
    showSpend(value);
    return;
  }
  if (group === 'account' && value?.credentials) {
    details([['Account', value.account], ['Credentials', value.credentials]]);
    showAccounts([{ ...state.getAccount(value.account), usage: value.usage }]);
    return;
  }
  if (group === 'router' && value?.release) {
    details([
      ['CCR version', value.release], ['Runtime', value.code_stale ? `${value.health} (pre-update code)` : value.health], ['Installed', value.installed ? 'yes' : 'no'],
      ['Routing', value.enabled ? 'enabled' : 'disabled'], ['Plain CLI routing', value.native_routing ? 'through Dex' : 'native subscriptions'], ['Accounts', value.accounts],
      ['Models', value.models], ['Active sessions', value.active_sessions], ['Credentials', value.credential_store]
    ]);
    if (!value.installed) out('Run dx router setup to install the optional runtime.');
    if (value.code_stale) out('The running gateway loaded its code before the current Dex version and keeps serving it. Finish routed sessions, then run dx router restart.');
    if (value.telemetry_failures) out(`Request telemetry could not be saved ${value.telemetry_failures} times. Inspect private router-state permissions before relying on request diagnostics.`);
    if (value.native_routing) out('Restore independent claude and codex launches with dx router native disable, then start new CLI sessions.');
    return;
  }
  if (group === 'profile') {
    // set and clear return the whole config; list returns the pairs. Both end
    // up as the same table, because what the caller wants to see either way is
    // the names a route may now use.
    const profiles = Array.isArray(value) ? value : Object.entries(value?.profiles || {}).map(([name, model]) => ({ name, model }));
    if (!profiles.length) { out('No profiles assigned. Name one with dx profile set <name> <provider/model>.'); return; }
    showTable(['Profile', 'Model'], profiles.map(profile => [`@${profile.name}`, profile.model]));
    return;
  }
  display(value, false);
}
async function configure(change, catalogueChange = false) {
  return state.locked('runtime', () => state.locked('config', () => {
    if (catalogueChange) adapter.idle();
    const previous = state.config(); const config = structuredClone(previous); change(config);
    if (config.default_model) policy.contextLimit(config);
    for (const session of state.sessions().filter(require('./service.cjs').active)) policy.route(config, session);
    state.write(state.stateFile('config'), config);
    try { require('./native.cjs').syncContext(config); }
    catch (error) { state.write(state.stateFile('config'), previous); throw error; }
    return config;
  }));
}
function spanLabel(milliseconds, round = Math.ceil) {
  const minutes = round(milliseconds / 60000);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h ${minutes % 60}m` : `${Math.floor(hours / 24)}d ${hours % 24}h`;
}
function resetIn(timestamp, now) {
  // Nothing to say reads better as a dash than as a word.
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '-';
  if (timestamp <= now) return 'due';
  return spanLabel(timestamp - now);
}
// Every cap an account has is either the one that comes back soon or the one
// that comes back later. Naming the columns after the period suited one
// provider; naming them after the horizon suits all of them.
const SHORT_TERM = new Set(['5h', 'credit']);
function windowSlot(name) { return SHORT_TERM.has(name) ? 'short' : 'long'; }

// The cap that binds is the one with least left, so that is the one shown.
function slotWindow(windows, slot) {
  const found = windows.filter(window => windowSlot(window.name) === slot);
  return found.length ? found.reduce((a, b) => (a.remaining_ratio ?? 1) <= (b.remaining_ratio ?? 1) ? a : b) : null;
}

// Short term and Long term report what is left, not what has gone lately,
// which is what a glance at a running account usually wants. Recent usage
// reports that, where it can be known. A window no longer than a day gives it
// directly: it opened empty, so what is missing from it went in since. A
// weekly window does not; nothing left may be a week of steady work or one
// afternoon of it. There it is measured across readings, and withheld until
// there are two readings to compare.
const RECENT_SPAN_MS = 86400000;

// A reading taken before the gateway recorded window lengths still has to
// render, so a name that implies a period is read as one, and a spend cap
// falls back to the period its key limit resets on.
function windowPeriod(window, usage, now) {
  return window.period_ms ?? NAMED_PERIOD_MS[window.name]
    ?? (window.name === 'spend-limit' ? periodLength(usage?.spend?.key_limit_period, now) : undefined);
}
// Shortest window first, and where two are the same length the one with least
// left, for the same reason the columns beside it show that one.
function shortestWindow(windows) {
  return windows.reduce((a, b) => b.period_ms < a.period_ms
    || (b.period_ms === a.period_ms && (b.remaining_ratio ?? 1) < (a.remaining_ratio ?? 1)) ? b : a);
}
// What successive readings of one window show going out of it. A window that
// refills has reset rather than gained, so only the drops count as spending.
function measuredUsage(history, window, observedAt, now) {
  const readings = [...(Array.isArray(history) ? history : [])
    .filter(sample => Number.isFinite(sample?.at) && sample.at < observedAt
      && now - sample.at <= RECENT_SPAN_MS && Number.isFinite(sample.windows?.[window.name]))
    .map(sample => ({ at: sample.at, remaining: sample.windows[window.name] })),
    { at: observedAt, remaining: window.remaining_ratio ?? 1 }].sort((a, b) => a.at - b.at);
  if (readings.length < 2) return null;
  const used = readings.slice(1).reduce((total, reading, index) =>
    total + Math.max(0, readings[index].remaining - reading.remaining), 0);
  return { ratio: Math.min(1, used), span: readings[readings.length - 1].at - readings[0].at };
}
function recentUsage(windows, account, now = Date.now()) {
  const usage = account?.usage;
  const timed = windows.map(window => ({ ...window, period_ms: windowPeriod(window, usage, now) }))
    .filter(window => Number.isFinite(window.period_ms) && window.period_ms > 0);
  if (!timed.length) return null;
  const short = timed.filter(window => window.period_ms <= RECENT_SPAN_MS);
  if (!short.length) return measuredUsage(account?.usage_history, shortestWindow(timed), Number(usage?.observed_at) || now, now);
  const window = shortestWindow(short);
  // The window opened empty, so how long it has been open is the span its
  // spending covers.
  const elapsed = Number.isFinite(window.resets_at) && window.resets_at > now
    ? Math.max(0, Math.min(window.period_ms, window.period_ms - (window.resets_at - now))) : null;
  return { ratio: 1 - (window.remaining_ratio ?? 1), span: elapsed };
}
function recentCell(recent) {
  if (!recent) return '-';
  return `${Math.round(recent.ratio * 100)}%${recent.span ? ` · ${spanLabel(recent.span, Math.round)}` : ''}`;
}

// What a cap reports beside the percentage: when it comes back, or, for a
// balance that never resets, how much of it is left.
function windowDetail(window, now) {
  const reset = resetIn(window.resets_at, now);
  if (reset !== '-') return reset;
  return Number.isFinite(window.remaining_amount) ? `$${window.remaining_amount.toFixed(2)}` : '';
}
function accountModels(account, config, now) {
  const ids = [...new Set([config.default_model, ...Object.values(config.phases).flatMap(route => [route.model, ...(route.fallbacks || [])]),
    ...Object.values(config.client_routes || {}).flatMap(route => [route.model, ...(route.fallbacks || [])]),
    ...Object.entries(account.model_cooldowns || {}).filter(([, until]) => until > now).map(([id]) => id)])];
  const models = ids.map(id => config.models.find(model => model.id === id)).filter(model => model?.provider === account.provider);
  return models.length ? models : [null];
}
// Money, only for accounts billed in it. A subscription's cost is its plan,
// so it has nothing to show here and gets a dash rather than a zero.
function spendCell(account) {
  const spend = account.usage?.spend;
  if (!spend) return '-';
  const money = value => value === undefined ? null : `$${value.toFixed(2)}`;
  const used = money(spend.used) ?? money(spend.key_used);
  if (!used) return '-';
  return spend.limit === undefined ? used : `${used} / ${money(spend.limit)}`;
}
function anySpend(items) { return items.some(account => spendCell(account) !== '-'); }

function accountRows(items, now = Date.now(), config = state.config()) {
  // The registry appends on add and reauth, so file order drifts from rank order.
  return policy.rankOrder(items).flatMap(account => accountModels(account, config, now).map(model => {
    const usage = account.usage;
    const fresh = usage && now - usage.observed_at < 120000 && !account.usage_error;
    const windows = (usage?.windows || []).filter(window => !model || !window.model_pool || model.id.includes(window.model_pool));
    const exhausted = fresh && windows.some(window => !window.model_pool && window.remaining_ratio === 0 && (!window.resets_at || window.resets_at > now));
    const reasons = { disabled: 'disabled', 'reauth-required': 'reauth-required', 'model-unavailable': 'not available',
      temporary: 'temporary provider error', 'connection-failed': 'connection failed', 'refresh-unavailable': 'login refresh unavailable', 'rate-limit': 'rate limited',
      'terms-required': 'accept terms in claude.ai' };
    const limits = Object.entries(account.model_cooldowns || {}).filter(([, until]) => until > now)
      .map(([model, until]) => `${model.split('/').pop()} ${reasons[account.model_cooldown_reasons?.[model]] || 'rate limited'} (${policy.retryIn(until, now)})`);
    const reason = reasons[account.cooldown_reason] || 'cooldown';
    const summary = !account.enabled ? 'disabled' : account.status === 'reauth-required' ? 'reauth-required'
      : account.cooldown_until > now ? `${reason} (${policy.retryIn(account.cooldown_until, now)})`
        : exhausted ? 'exhausted' : limits.join('; ') || 'ready';
    const status = model ? policy.blockers(account, model, now).map(problem => {
      const label = problem.reason === 'quota-exhausted' ? 'exhausted' : reasons[problem.reason] || 'cooldown';
      return `${label}${problem.until > now && problem.reason !== 'quota-exhausted' ? ` (${policy.retryIn(problem.until, now)})` : ''}`;
    }).join('; ') || 'ready' : summary;
    return [account.name, account.rank || '-', account.provider, model ? (model.display_name || model.id.split('/')[1]).replace(/^Claude /, '') : '-', status,
      recentCell(recentUsage(windows, account, now)),
      ...['short', 'long'].map(slot => {
      const window = slotWindow(windows, slot);
      if (!window) return '-';
      const detail = windowDetail(window, now);
      return `${Math.round(window.remaining_ratio * 100)}%${detail ? ` · ${detail}` : ''}`;
    })];
  }));
}
// One rule between vendors. Accounts stay in rank order; the break only marks
// where the provider changes, so a vendor's rows read as a block.
function groupByProvider(rows, column = 2) {
  return rows.flatMap((row, index) =>
    index && row[column] !== rows[index - 1][column] ? [null, row] : [row]);
}

// A metered account is billed in money, so its detail view says so in money.
function showSpend(account) {
  const spend = account.usage?.spend;
  if (!spend) return;
  const money = value => value === undefined ? null : `$${value.toFixed(2)}`;
  const rows = [];
  if (spend.limit !== undefined) rows.push(['Balance', `${money(spend.remaining)} left of ${money(spend.limit)}`]);
  if (spend.used !== undefined) rows.push(['Account spent', money(spend.used)]);
  if (spend.key_used !== undefined && spend.key_used !== spend.used) rows.push(['This key spent', money(spend.key_used)]);
  if (spend.key_limit !== undefined) {
    const period = spend.key_limit_period ? `, resets ${spend.key_limit_period}` : '';
    rows.push(['Spend limit', `${money(spend.key_remaining) ?? money(spend.key_limit - (spend.key_used ?? 0))} left of ${money(spend.key_limit)}${period}`]);
  }
  for (const [label, key] of [['Today', 'daily'], ['This week', 'weekly'], ['This month', 'monthly']]) {
    if (spend[key] !== undefined) rows.push([label, money(spend[key])]);
  }
  if (spend.free_requests) rows.push(['Free model requests', `${spend.free_requests.remaining} left of ${spend.free_requests.limit} today`]);
  if (spend.free_tier) rows.push(['Tier', 'free']);
  if (spend.expires_at) rows.push(['Key expires', new Date(spend.expires_at).toISOString().slice(0, 10)]);
  if (rows.length) details(rows);
}

const MODEL_COLUMN = 3;
function mergeModelRows(rows) {
  const merged = [];
  for (const row of rows) {
    const previous = merged[merged.length - 1];
    const same = previous && previous.length === row.length
      && previous.every((cell, index) => index === MODEL_COLUMN || cell === row[index]);
    if (same) previous[MODEL_COLUMN] = `${previous[MODEL_COLUMN]}, ${row[MODEL_COLUMN]}`;
    else merged.push([...row]);
  }
  return merged;
}

function accountTable(items) {
  const headers = ['Account', 'Rank', 'Provider', 'Model', 'Status', 'Recent usage', 'Short term', 'Long term'];
  return table(headers, groupByProvider(mergeModelRows(accountRows(items, Date.now()))),
    { rightAlign: [1, 5, 6, 7] });
}
function showAccounts(items) {
  process.stdout.write(accountTable(items));
}
function accountsFrame(items, live, note = '') {
  const rows = accountTable(items) || 'No accounts. Run dx account add.\n';
  const footer = live
    ? `View updated at ${new Date().toLocaleTimeString()}\nLive: every 30s. Ctrl+C to exit.`
    : 'Tip: use dx accounts --live for updates.';
  return `Dex subscription accounts\n${rows}\n${note ? `${note}\n` : ''}${footer}\n`;
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
      if (options.json) display({ version: 1, accounts: policy.rankOrder(items) }, true);
      else if (screen) screen.render(accountsFrame(items, true, note), note ? 4 : 2);
      else process.stdout.write(accountsFrame(items, false));
      if (screen) await new Promise(resolve => setTimeout(resolve, 30000));
    } while (screen);
  } finally { screen?.close(); }
}
async function addAccount(provider, options, previous) {
  if (!provider) {
    out('1. Anthropic Claude'); out('2. OpenAI ChatGPT / Codex'); out('3. OpenRouter API key (metered)');
    const selected = await question('Provider', '1');
    provider = { 1: 'anthropic', 2: 'openai', 3: 'openrouter' }[selected];
    if (!provider) throw new Error('Choose 1, 2 or 3.');
  }
  const metered = providerKind(provider) === 'api-key';
  const name = options.name || previous?.name || await question('Account name', `${provider}-${state.accounts().filter(item => item.provider === provider).length + 1}`);
  let apiKey;
  if (metered) {
    const variable = PROVIDERS[provider].key_env;
    // Read from the environment or typed at the prompt, then handed straight to
    // the credential store. There is deliberately no flag for it: an argv value
    // is world-readable in ps. It is never echoed, stored in config, or logged.
    apiKey = process.env[variable] || await question(`${PROVIDERS[provider].label} API key (or set ${variable})`);
    info(`${PROVIDERS[provider].label} bills per token. Add models explicitly with dx model add.`);
  } else info(`Opening ${provider} subscription login. Existing accounts stay signed in.`);
  const result = await onboarding.register({ provider, name, apiKey, device: options.device, reauth: previous?.id, confirm: identity => confirm(`Register ${clean(identity)} as ${clean(name)}?`, options.yes) });
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
  if (action === 'show') {
    // A single account needs no gateway to answer for itself, and reading it
    // here means the detail is this version's, not whatever the running router
    // last stored. A provider that will not answer leaves the cached reading.
    try {
      const { AccountBroker } = require('./accounts.cjs');
      const usage = await new AccountBroker().usage({ ...account, usage: undefined });
      return await state.locked('accounts', () => {
        const items = state.accounts(); const current = state.getAccount(account.id, items);
        current.usage = usage; delete current.usage_error; state.saveAccounts(items);
        return current;
      });
    } catch { return account; }
  }
  if (action === 'reauth') return addAccount(account.provider, options, account);
  if (action === 'doctor') {
    const { AccountBroker } = require('./accounts.cjs'); await new AccountBroker().access(account); return { account: account.name, credentials: 'renewable', usage: account.usage || null };
  }
  if (action === 'remove' && !await confirm(`Remove ${account.name} and delete its stored login?`, options.yes)) return 'Account retained.';
  return onboarding.changeAccount(action, args[0], args[1]);
}
// Rates are USD per million tokens. A model priced on one side only would make
// every estimate from it wrong in a way nothing downstream could detect, so
// both sides are required together; the cache rate is optional because input
// falls back to the full rate, which overstates rather than understates.
function modelPricing(options) {
  const rate = (flag, required) => {
    if (options[flag] === undefined) {
      if (required) throw new Error('Price a model on both sides: give --price-in and --price-out in USD per million tokens, or neither.');
      return undefined;
    }
    const value = Number(options[flag]);
    if (!Number.isFinite(value) || value < 0 || value > 10000) throw new Error(`--${flag} must be a rate in USD per million tokens between 0 and 10000.`);
    return value;
  };
  const priced = options['price-in'] !== undefined || options['price-out'] !== undefined;
  if (!priced) {
    if (options['price-cached'] !== undefined) throw new Error('A cached-input rate needs --price-in and --price-out as well.');
    return undefined;
  }
  return { input_per_mtok: rate('price-in', true), output_per_mtok: rate('price-out', true),
    ...(options['price-cached'] === undefined ? {} : { cached_input_per_mtok: rate('price-cached') }) };
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
  if (action !== 'add' || !policy.MODEL.test(args[0] || '')) throw new Error(`Use dx model add <provider/model> --context <tokens> --tools [--images] [--upstream <id>] [--max-context <tokens>] [--price-in <usd/Mtok> --price-out <usd/Mtok>]. Providers: ${policy.PROVIDER_NAMES.join(', ')}.`);
  const context = Number(options.context);
  if (!Number.isSafeInteger(context) || context < 8192 || context > 4000000 || !options.tools) throw new Error('Specify a supported context window (8192–4000000) and confirm --tools support.');
  // An aggregator's own ID carries a vendor segment, so the Dex ID stays stable
  // and short while --upstream records what the provider is actually called.
  const upstream = options.upstream || args[0].split('/')[1];
  if (!/^[A-Za-z0-9][A-Za-z0-9._:+/-]*$/.test(upstream)) throw new Error('An upstream model ID may contain letters, numbers and . _ : + - /.');
  const maximum = options['max-context'] === undefined ? undefined : Number(options['max-context']);
  if (maximum !== undefined && (!Number.isSafeInteger(maximum) || maximum < context || maximum > 4000000)) throw new Error('A maximum context window must be an integer between the default window and 4000000.');
  const pricing = modelPricing(options);
  const model = { id: args[0], upstream_id: upstream, provider: args[0].split('/')[0], context_window: context, default_context_window: context,
    ...(maximum === undefined ? {} : { max_context_window: maximum }), ...(pricing ? { pricing } : {}),
    context_source: 'user', capabilities: { tools: true, images: Boolean(options.images) } };
  await configure(config => { config.models = [...config.models.filter(item => item.id !== model.id), model]; }, true);
  if (await adapter.health()) { await adapter.stop(); await adapter.start(); } return model;
}
// A route may name a profile: @cheap, @strong, @near_frontier, @frontier. It
// is stored as given, resolved where the route is read, and must resolve to a
// configured model at the moment the route is saved — a profile that names
// nothing would otherwise make the route unlaunchable.
function resolveForSave(config, ids) {
  return policy.resolveProfiles(structuredClone(config), ids);
}

async function routeCommand(action, args, options) {
  if (action === 'configure') {
    const model = args[0] || await question('Default model (provider/model)');
    return configure(config => {
      const fallbacks = options.fallback || [];
      const resolved = resolveForSave(config, [model, ...fallbacks]);
      resolved.forEach(id => policy.model(config, id));
      if (options.effort && !['minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(options.effort)) throw new Error('Unknown reasoning effort.');
      if (options.client && options.phase !== undefined) throw new Error('Choose either --client or --phase, not both.');
      if (options.client && !['claude', 'codex'].includes(options.client)) throw new Error('Client must be claude or codex.');
      const choice = { model, fallbacks, ...(options.effort ? { effort: options.effort } : {}) };
      // A save must prove each profile resolves; the stored choice keeps the
      // profile names so re-pointing one later re-targets the route.
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
// Profiles name the role a model plays — cheap, strong, near_frontier,
// frontier — so a route can be expressed once and re-pointed later.
async function profileCommand(action, args, options) {
  if (action === 'list' || action === undefined) {
    const profiles = state.config().profiles || {};
    return Object.entries(profiles).map(([name, model]) => ({ name, model }));
  }
  const name = args[0];
  if (!policy.PROFILE.test(`@${name}`)) throw new Error('A profile name is 1–32 lowercase letters, numbers, hyphens or underscores, starting with a letter.');
  if (action === 'set') {
    const model = args[1];
    policy.model(state.config(), model);
    return configure(config => { config.profiles ||= {}; config.profiles[name] = model; });
  }
  if (action === 'clear') {
    return configure(config => {
      if (!config.profiles?.[name]) throw new Error(`Profile ${name} is not assigned.`);
      // A route naming the profile would stop resolving the moment it is gone,
      // so the routes that still point at it are named and the clear is refused.
      const users = [];
      const visit = (route, label) => {
        if (route?.model === `@${name}` || (route?.fallbacks || []).includes(`@${name}`)) users.push(label);
      };
      for (const [phase, route] of Object.entries(config.phases || {})) visit(route, `phase ${phase}`);
      for (const [client, route] of Object.entries(config.client_routes || {})) visit(route, `client ${client}`);
      if (config.default_model === `@${name}`) users.push('the default route');
      if (users.length) throw new Error(`Profile ${name} is named by ${users.join(', ')}. Re-point or reconfigure those first.`);
      delete config.profiles[name];
    });
  }
  throw new Error('Use dx profile list, dx profile set <name> <provider/model> or dx profile clear <name>.');
}

// Returns what sync-context changed, or null when native routing is off. A
// failure here must not make a working restart look failed, so it is reported
// rather than thrown: the router is up either way.
async function syncNative() {
  try { return await state.locked('config', () => require('./native.cjs').syncContext()) || null; }
  catch (error) { return { error: error.message }; }
}
function syncedNote(result) {
  if (!result) return '';
  if (result.error) return ` Client settings were not refreshed: ${result.error}`;
  if (!result.changed) return '';
  return ` Native client settings refreshed${result.preserved?.length ? `, keeping your edits to ${result.preserved.join(', ')}` : ''}; restart running clients to pick them up.`;
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
    return 'CCR routing is ready. Use dx router disable to restore native CLI access if needed.';
  }
  if (action === 'enable') { await configure(config => { policy.contextLimit(config); config.enabled = true; }); await adapter.start(); return 'CCR routing enabled.'; }
  if (action === 'disable') {
    const restored = await require('./native.cjs').disable({ router: true });
    return `CCR routing disabled for new sessions. ${restored} Start a new terminal session and run claude or codex for native access. Running routed sessions can finish. Run dx router enable to resume CCR-backed Dex sessions.`;
  }
  if (action === 'stop') return adapter.stop();
  if (action === 'ui') { await adapter.openUI(); return 'Opened the private CCR dashboard. Dex account and routing settings are managed by dx commands.'; }
  // Restarting is how someone picks up a new Dex version, so it also carries
  // that version's managed client settings across. A field added since the
  // install landed would otherwise wait for an unrelated route or catalogue
  // change, and a restart would look like it had applied the upgrade when it
  // had not. sync-context is the migration channel: it adopts what is missing
  // and leaves values edited by hand alone.
  if (action === 'restart') { await adapter.stop(); await adapter.start(); return `CCR restarted.${syncedNote(await syncNative())}`; }
  if (action === 'start') {
    if (!state.config().enabled) throw new Error('Run dx router setup or enable first.');
    // adapter.start() returns the existing endpoint when a gateway answers, so
    // start alone cannot pick up a Dex update. Say so rather than report a
    // success that leaves the old code serving every request.
    const running = await adapter.health(true);
    if (adapter.stale(running)) return 'CCR is already running, on code from before the current Dex version; dx router start leaves it in place. Finish routed sessions, then run dx router restart to load it.';
    await adapter.start(); return `CCR started.${syncedNote(await syncNative())}`;
  }
  if (action === 'update') { adapter.idle(); await adapter.install(); return `Using tested release ${adapter.RELEASE}. CCR upgrades ship with Dex after contract tests pass.`; }
  if (action === 'status' || action === 'doctor') {
    let installed = false; try { adapter.verifyRuntime(); installed = true; } catch { /* Report as a diagnostic. */ }
    const health = await adapter.health();
    const sessions = health ? await ipc.call('health', { sessions: true }) : null;
    return { version: 1, enabled: state.config().enabled, native_routing: state.config().native?.enabled === true, release: adapter.RELEASE, installed, health: health ? 'running' : 'stopped', code_stale: adapter.stale(health), telemetry_failures: health?.telemetry_failures || 0, active_sessions: sessions?.active_sessions || 0, accounts: state.accounts().length, models: state.config().models.length, credential_store: process.platform === 'darwin' ? 'macOS Keychain' : 'owner-only file' };
  }
  if (action === 'check') {
    if (!state.config().enabled || !state.accounts().some(item => item.enabled)) throw new Error('CCR needs setup and an enabled account. Run dx router setup.');
    policy.contextLimit(state.config()); adapter.verifyRuntime(); return undefined;
  }
  throw new Error(`Unknown router command: ${action}`);
}
async function contextCommand(action, values, options) {
  const context = require('./context.cjs');
  if (action === 'doctor') return context.doctor(options);
  if (action === 'refresh') return context.refresh(configure);
  if (action === 'scope') {
    if (values[0] === 'off') { await configure(config => { config.mcp_scope = { enabled: false }; }); return 'Scoped MCP loading is disabled for new Dex launches.'; }
    if (values.length || !options.include.length) throw new Error('Use dx context scope --include <server> [--include <server> ...] [--builtin-tools <names>], or dx context scope off.');
    const selection = { enabled: true, include: options.include,
      ...(options['builtin-tools'] ? { builtin_tools: options['builtin-tools'].split(',') } : {}) };
    const scoped = require('./mcp-scope.cjs').scope(selection);
    await configure(config => { config.mcp_scope = selection; });
    return `Scoped MCP loading saved for new Dex launches. Selected here: ${scoped.summary.selected.join(', ') || 'none'}. Global registrations are retained. Use dx context scope off to restore inherited loading.`;
  }
  if (action === 'budget') {
    if (!/^[1-9][0-9]*$/.test(values[0] || '')) throw new Error('Context budget requires a positive integer token count.');
    const budget = Number(values[0]);
    await configure(config => { config.context_budget = budget; policy.contextLimit(config); for (const client of Object.keys(config.client_routes || {})) policy.contextLimit(config, client); });
    return `Operating context budget set to ${budget} tokens. Resume existing conversations in new client launches to apply it; transcripts and worktrees are retained.`;
  }
  throw new Error('Use dx context doctor, refresh, scope or budget <tokens>.');
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
        : group === 'route' ? (['status', 'policy', 'unpin-account', undefined].includes(action) ? [0, 0] : [1, 1])
          : group === 'profile' ? (['list', undefined].includes(action) ? [0, 0] : action === 'set' ? [2, 2] : [1, 1])
          : group === 'context' ? (action === 'budget' ? [1, 1] : action === 'scope' ? [0, 1] : [0, 0]) : [0, 0];
  const provided = group === 'accounts' ? options.positional.length : values.length;
  if (provided < arity[0] || provided > arity[1]) throw new Error(`Unexpected arguments for dx ${group}${action ? ` ${action}` : ''}. Run dx ${group} --help.`);
  let result;
  if (group === 'accounts') { await accounts(options); return; }
  if (group === 'account') result = await accountCommand(action || 'list', values, options);
  else if (group === 'model') result = await modelCommand(action || 'list', values, options);
  else if (group === 'route') result = await routeCommand(action || 'status', values, options);
  else if (group === 'profile') result = await profileCommand(action, values, options);
  else if (group === 'router') result = await routerCommand(action || 'status', options, values);
  else if (group === 'context') result = await contextCommand(action || 'doctor', values, options);
  else throw new Error('Unknown subscription routing command.');
  if (result !== undefined) render(group, action || (group === 'model' ? 'list' : 'status'), result, options);
}
if (require.main === module) {
  process.umask(0o077);
  main(process.argv.slice(2)).catch(error => { info(error.message); process.exitCode = 1; });
}
module.exports = { clean, parse, question, configure, accountRows, accountTable, groupByProvider, mergeModelRows, slotWindow, windowDetail, recentUsage, recentCell, accountCommand, modelCommand, profileCommand, routeCommand, routerCommand, main };
