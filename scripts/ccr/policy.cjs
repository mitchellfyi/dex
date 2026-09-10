'use strict';

const fs = require('node:fs');
const state = require('./state.cjs');

const PHASES = ['setup', 'plan', 'implement', 'review', 'verify', 'pr', 'complete'];
const MODEL = /^(anthropic|openai)\/[A-Za-z0-9][A-Za-z0-9._:+-]*$/;

function model(config, id) {
  if (typeof id !== 'string' || !MODEL.test(id)) throw new Error('Use a model listed by dx model list.');
  const found = config.models.find(item => item.id === id);
  if (!found || !Number.isInteger(found.context_window) || found.context_window < 8192) throw new Error(`Model is not configured: ${id}`);
  return found;
}

function phase(session) {
  if (session.fixed_phase !== undefined) {
    if (!Number.isInteger(session.fixed_phase) || session.fixed_phase < 0 || session.fixed_phase > 6) throw new Error('Invalid fixed phase.');
    return session.fixed_phase;
  }
  if (!session.phase_file) return 0;
  try {
    const metadata = fs.lstatSync(session.phase_file);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== process.getuid() || (metadata.mode & 0o022) || metadata.size > 32) throw new Error('Unsafe lifecycle phase file.');
    const value = fs.readFileSync(session.phase_file, 'utf8').trim();
    if (!/^[0-6]$/.test(value)) throw new Error('Invalid lifecycle phase.');
    return Number(value);
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error('Lifecycle phase is missing. Resume the Dex lifecycle before continuing.');
    throw error;
  }
}

function route(config, session) {
  const current = phase(session);
  const override = session.override;
  const choice = override && (override.scope === 'session' || override.phase === current)
    ? override : config.phases[current] || config.phases[PHASES[current]] || { model: config.default_model, fallbacks: [] };
  const ids = [choice.model, ...(choice.fallbacks || [])];
  const models = [...new Set(ids)].map(id => model(config, id));
  if (session.context_limit && models.some(item => item.context_window < session.context_limit)) throw new Error('This route has a smaller context window than the running session. Start a new session with this policy.');
  return { phase: current, models, effort: choice.effort, pinned: session.pinned_account };
}

function contextLimit(config) {
  const choices = Object.values(config.phases).flatMap(value => [value.model, ...(value.fallbacks || [])]);
  if (config.default_model) choices.push(config.default_model);
  if (!choices.length) throw new Error('Choose a default model with dx route configure.');
  return Math.min(...choices.map(id => model(config, id).context_window));
}

function candidates(items, selection, session, now = Date.now()) {
  const result = [];
  for (const target of selection.models) {
    const windows = account => account.usage && now - account.usage.observed_at < 120000 && !account.usage_error
      ? account.usage.windows.filter(window => (!window.model_pool || target.id.includes(window.model_pool)) && (!window.resets_at || window.resets_at > now)) : [];
    const available = items.filter(item => item.enabled && item.provider === target.provider && item.status !== 'reauth-required'
      && (!selection.pinned || item.id === selection.pinned)
      && (!item.model_ids || item.model_ids.includes(target.id))
      && !windows(item).some(window => window.remaining_ratio === 0)
      && !(item.cooldown_until > now) && !(item.model_cooldowns?.[target.id] > now));
    available.sort((a, b) => {
      if (a.id === session.current_account) return -1;
      if (b.id === session.current_account) return 1;
      const remaining = account => windows(account).length ? Math.min(...windows(account).map(window => window.remaining_ratio ?? 1), 1) : 0.5;
      return remaining(b) - remaining(a) || a.created_at - b.created_at;
    });
    for (const account of available) result.push({ account, model: target, effort: selection.effort });
    if (selection.pinned) break;
  }
  return result;
}

function failure(status, payload = {}, headers = {}, now = Date.now()) {
  const type = payload.error?.type || payload.error?.code || payload.type || '';
  if (status === 401) return { retry: true, reauth: true, reason: 'authentication' };
  if (status === 429) {
    const after = headers.get ? headers.get('retry-after') : headers['retry-after'];
    const delay = /^\d+(\.\d+)?$/.test(after || '') ? Number(after) * 1000 : Date.parse(after) - now;
    const reset = Number(payload.error?.resets_at || payload.resets_at) * 1000;
    return { retry: true, reason: 'rate-limit', until: Math.max(now + 1000, Number.isFinite(reset) && reset > now ? reset : now + (Number.isFinite(delay) ? delay : 60000)), modelOnly: /model/.test(type) };
  }
  if ([408, 409, 500, 502, 503, 504, 529].includes(status)) return { retry: true, reason: 'temporary', until: now + 10000 };
  return { retry: false, reason: status === 403 ? 'forbidden' : 'request-rejected' };
}

function validateRequest(body, target) {
  if (!body || !Array.isArray(body.messages)) throw new Error('A Messages request with a messages array is required.');
  const capabilities = target.capabilities || {};
  function visit(value) {
    if (Array.isArray(value)) { value.forEach(visit); return; }
    if (!value || typeof value !== 'object') return;
    if (value.type === 'image' && capabilities.images !== true) throw new Error('The selected model has no verified image support.');
    if (['document', 'tool_reference', 'web_search_tool_result'].includes(value.type) && target.provider === 'openai') throw new Error(`The selected route cannot preserve ${value.type} content.`);
    Object.values(value).forEach(visit);
  }
  visit(body.messages);
  if (body.tools?.length && capabilities.tools !== true) throw new Error('The selected model has no verified tool support.');
  // This is a payload guard, not a tokenizer. Native compaction uses the smallest
  // configured context window; providers remain authoritative about token limits.
  if (Buffer.byteLength(JSON.stringify(body)) > target.context_window * 4) throw new Error('The conversation exceeds this route’s payload budget. Compact it before switching.');
}

module.exports = { PHASES, model, phase, route, contextLimit, candidates, failure, validateRequest };
