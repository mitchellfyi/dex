'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const state = require('./state.cjs');
const policy = require('./policy.cjs');
const { LONG_CONTEXT_BETA, LONG_CONTEXT_MARKER } = require('./claude-picker.cjs');
const LONG_CONTEXT_MARKER_PATTERN = new RegExp(`${LONG_CONTEXT_MARKER.replace(/[[\]]/g, '\\$&')}$`, 'i');
const count = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
const optionalCount = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
const label = value => typeof value === 'string' && /^[A-Za-z0-9_.:/[\]-]{1,180}$/.test(value) ? value : 'unknown';
const timestamp = value => typeof value === 'string' && Number.isFinite(Date.parse(value)) ? value : null;

async function readTranscript(file, budget) {
  let fd;
  try { fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
  catch (error) { if (error.code === 'ELOOP') throw new Error('Transcript symlinks are not accepted.'); throw error; }
  const info = fs.fstatSync(fd);
  if (!info.isFile() || info.uid !== process.getuid() || info.size > 1024 * 1024 * 1024) {
    fs.closeSync(fd); throw new Error('Transcript must be a safe owned regular file under 1 GiB.');
  }
  const report = { compactions: [], recent_requests: [], tool_count: 0, tool_schema_bytes: 0, tool_groups: {},
    restored_skill_characters: 0, restored_instruction_characters: 0, thrashing: false, incomplete_records: 0, oversized_records: 0 };
  const requests = new Map(); let pendingCompact, lineNumber = 0, lastThrash = 0, lastReal = 0;
  const observe = line => {
    lineNumber++;
    let row; try { row = JSON.parse(line); } catch { report.incomplete_records++; return; }
    if (!row || typeof row !== 'object') { report.incomplete_records++; return; }
    if (row.subtype === 'compact_boundary' && row.compactMetadata) {
      const metadata = row.compactMetadata;
      pendingCompact = { timestamp: timestamp(row.timestamp), pre_tokens: optionalCount(metadata.preTokens), post_tokens: optionalCount(metadata.postTokens), duration_ms: optionalCount(metadata.durationMs), next_input_tokens: null };
      report.compactions.push(pendingCompact); if (report.compactions.length > 20) report.compactions.shift();
    }
    const attachment = row.attachment;
    if (attachment?.type === 'invoked_skills' && Array.isArray(attachment.skills)) report.restored_skill_characters = attachment.skills.reduce((sum, item) => sum + (typeof item.content === 'string' ? item.content.length : 0), 0);
    if (attachment?.type === 'instructions' && Array.isArray(attachment.files)) report.restored_instruction_characters = attachment.files.reduce((sum, item) => sum + (typeof item.content === 'string' ? item.content.length : 0), 0);
    if (attachment?.type === 'prompt_snapshot' && Array.isArray(attachment.tools)) {
      report.tool_count = attachment.tools.length; report.tool_schema_bytes = 0; report.tool_groups = {};
      for (const tool of attachment.tools) {
        const name = label(tool.name), group = name.startsWith('mcp__') ? name.split('__').slice(0, 2).join('__') : 'built-in';
        report.tool_groups[group] = (report.tool_groups[group] || 0) + 1;
        report.tool_schema_bytes += Buffer.byteLength(JSON.stringify(tool.schema || {}));
      }
    }
    const message = row.message;
    const content = Array.isArray(message?.content) ? message.content : [];
    if (row.type === 'assistant' && content.some(block => typeof block.text === 'string' && block.text.startsWith('Autocompact is thrashing:'))) lastThrash = lineNumber;
    if (row.type === 'assistant' && message?.usage && message.model !== '<synthetic>') {
      const usage = message.usage;
      const input = count(usage.input_tokens) + count(usage.cache_read_input_tokens) + count(usage.cache_creation_input_tokens);
      if (!input) return;
      lastReal = lineNumber;
      const id = message.id || String(lineNumber);
      requests.set(id, { timestamp: timestamp(row.timestamp), model: label(message.model), input_tokens: input, output_tokens: count(usage.output_tokens) });
      if (requests.size > 20) requests.delete(requests.keys().next().value);
      if (pendingCompact && pendingCompact.next_input_tokens === null) pendingCompact.next_input_tokens = input;
    }
  };
  const stream = fs.createReadStream(file, { fd, autoClose: true, encoding: 'utf8' });
  let pending = '', skipping = false;
  for await (const chunk of stream) {
    const lines = chunk.split('\n');
    for (let index = 0; index < lines.length; index++) {
      if (!skipping) {
        pending += lines[index];
        if (pending.length > 8 * 1024 * 1024) { report.oversized_records++; pending = ''; skipping = true; }
      }
      if (index < lines.length - 1) {
        if (!skipping && pending.trim()) observe(pending);
        pending = ''; skipping = false;
      }
    }
  }
  if (pending.trim()) observe(pending);
  report.recent_requests = [...requests.values()];
  report.thrashing = lastThrash > lastReal;
  report.near_limit_after_compact = report.compactions.slice(-3).some(item => item.next_input_tokens !== null && item.next_input_tokens >= budget * 0.8 * 0.9);
  return report;
}

function transcriptPath(session) {
  if (!session?.cwd || !/^[a-f0-9-]{36}$/i.test(session.conversation_id || '')) return null;
  const root = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  return path.join(root, 'projects', session.cwd.replace(/[^a-zA-Z0-9]/g, '-'), `${session.conversation_id}.jsonl`);
}

// What the installed client settings actually make Claude Code do, which is
// not what the route configures. The client resolves a model's window locally
// from its name before any request, so an install left behind by an older Dex
// keeps compacting against a window the route never chose and nothing else in
// this report would show it. Read-only: dx router native sync installs the
// current values without restarting the router.
function clientSettings(config) {
  if (!config.enabled || !config.native?.enabled) return null;
  const file = config.native.claude_file
    || path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'settings.json');
  let claude;
  try { claude = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { return { file, stale: [error.code === 'ENOENT' ? 'No client settings are installed.' : 'Client settings could not be read.'] }; }
  const budget = policy.contextLimit(config, 'claude');
  const env = claude.env || {};
  const marked = typeof claude.model === 'string' && LONG_CONTEXT_MARKER_PATTERN.test(claude.model);
  const report = { file, model: label(claude.model || 'none'), long_context: marked,
    max_context_tokens: optionalCount(Number(env.CLAUDE_CODE_MAX_CONTEXT_TOKENS)),
    auto_compact_window: optionalCount(Number(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW)),
    long_context_beta: (env.ANTHROPIC_BETAS || '').split(',').includes(LONG_CONTEXT_BETA),
    tool_search: env.ENABLE_TOOL_SEARCH === 'true', stale: [] };
  if (!marked) report.stale.push(`The installed model ${report.model} carries no ${LONG_CONTEXT_MARKER} marker, so the client resolves its own window and ignores CLAUDE_CODE_MAX_CONTEXT_TOKENS.`);
  if (report.max_context_tokens !== budget) report.stale.push(`CLAUDE_CODE_MAX_CONTEXT_TOKENS is ${env.CLAUDE_CODE_MAX_CONTEXT_TOKENS ?? 'unset'}, not the route budget ${budget}.`);
  if (report.auto_compact_window === null) report.stale.push('CLAUDE_CODE_AUTO_COMPACT_WINDOW is unset, so compaction follows the window the client resolved rather than the route budget.');
  if (env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE !== undefined) report.stale.push(`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is ${env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE}; Dex no longer sets a percentage and states the window instead.`);
  if (!report.long_context_beta) report.stale.push('ANTHROPIC_BETAS does not request the 1M context beta, so the provider caps input below the route budget.');
  if (!report.tool_search) report.stale.push('ENABLE_TOOL_SEARCH is not on, so every tool definition loads up front and the conversation starts larger than it needs to.');
  return report;
}

async function doctor(options = {}) {
  const config = state.config();
  const id = options.session || process.env.DX_ROUTER_SESSION_ID;
  const session = id ? state.read(state.sessionFile(id)) : null;
  const budget = policy.contextLimit(config, session?.client);
  const report = { version: 1, session: session?.id || null, active: session ? require('./service.cjs').active(session) : false,
    configured_budget: budget, launch_budget: session?.context_limit || null,
    restart_required: Boolean(session && session.context_limit !== budget),
    current_model: session?.current_model || null, mcp_scope: session?.mcp_scope || null,
    models: config.models.map(model => ({ id: model.id, default: model.default_context_window || model.context_window,
      maximum: policy.modelCapacity(model), source: model.context_source || 'legacy', observed_at: model.observed_at || null })),
    last_request: session?.last_request || null, client_settings: clientSettings(config), transcript: null, advice: [] };
  const file = options.transcript || transcriptPath(session);
  if (file) {
    try { report.transcript = await readTranscript(file, session?.context_limit || budget); }
    catch (error) {
      if (options.transcript) throw error;
      report.transcript_error = error.code === 'ENOENT' ? 'No retained transcript was found for this conversation.' : 'Transcript could not be inspected safely.';
    }
  }
  if (report.client_settings?.stale.length) report.advice.push(`Installed client settings do not match this Dex: ${report.client_settings.stale.join(' ')} Run dx router native sync, then start a new client launch.`);
  if (report.restart_required) report.advice.push('Resume the saved conversation in a new client launch to use the configured budget; an existing process retains its launch budget.');
  if (report.transcript?.thrashing || report.transcript?.near_limit_after_compact) report.advice.push('Compaction leaves too little headroom. Inspect tool/schema and restored-skill sizes, scope MCPs to this worktree, and correct the context budget before resuming. Do not repeat compaction or clear the transcript blindly.');
  if (report.transcript?.tool_count > 80) report.advice.push('This session has a large tool set. Use a scoped MCP profile and one browser provider.');
  return report;
}

async function refresh(configure) {
  const config = state.config(), discovered = [], errors = [];
  const providers = [...new Set(config.models.filter(model => model.context_source !== 'user').map(model => model.provider))];
  for (const provider of providers) {
    let found;
    const accounts = state.accounts().filter(account => account.enabled && account.provider === provider && account.status !== 'reauth-required')
      .sort((a, b) => (a.rank || Number.MAX_SAFE_INTEGER) - (b.rank || Number.MAX_SAFE_INTEGER));
    for (const account of accounts) {
      try { found = await require('./onboarding.cjs').discover(account); break; }
      catch { /* Try the next registered login; credentials and errors stay private. */ }
    }
    if (found) discovered.push(...found); else errors.push(provider);
  }
  if (errors.length) throw new Error(`Context metadata unavailable for ${errors.join(', ')}. Existing limits were retained; check dx accounts and retry.`);
  const updated = [];
  await configure(next => {
    next.models = next.models.map(model => {
      const incoming = discovered.find(item => item.id === model.id);
      if (!incoming || model.context_source === 'user') return model;
      updated.push(model.id);
      const fields = Object.fromEntries(['context_window', 'default_context_window', 'max_context_window', 'max_output_tokens', 'context_source', 'observed_at'].filter(key => incoming[key] !== undefined).map(key => [key, incoming[key]]));
      return { ...model, ...fields };
    });
  });
  return { updated, message: 'Provider defaults and maximum windows refreshed. Running clients retain their launch budget; resume them after selecting the operating budget.' };
}
module.exports = { readTranscript, clientSettings, doctor, refresh };
