'use strict';

const fs = require('node:fs');
const state = require('./state.cjs');

const PHASES = ['setup', 'plan', 'implement', 'review', 'verify', 'pr', 'complete'];
// The lifecycle writes 7 once Phase 6 has a verified terminal commit. The
// session keeps talking (final summary, follow-up questions) on the complete
// route; 7 is never configurable on its own.
const TERMINAL_PHASE = 7;
const MODEL = /^(anthropic|openai)\/[A-Za-z0-9][A-Za-z0-9._:+-]*$/;
// Wire protocol each provider speaks without CCR conversion.
const NATIVE_PROTOCOL = { anthropic: 'messages', openai: 'responses' };

function model(config, id) {
  if (typeof id !== 'string' || !MODEL.test(id)) throw new Error('Use a model listed by dx model list.');
  const found = config.models.find(item => item.id === id);
  if (!found || !Number.isInteger(found.context_window) || found.context_window < 8192) throw new Error(`Model is not configured: ${id}`);
  return found;
}

function phase(session) {
  if (session.fixed_phase !== undefined) {
    if (!Number.isInteger(session.fixed_phase) || session.fixed_phase < 0 || session.fixed_phase > TERMINAL_PHASE) throw new Error('Invalid fixed phase.');
    return session.fixed_phase;
  }
  if (!session.phase_file) return 0;
  try {
    const metadata = fs.lstatSync(session.phase_file);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== process.getuid() || (metadata.mode & 0o022) || metadata.size > 32) throw new Error('Unsafe lifecycle phase file.');
    const value = fs.readFileSync(session.phase_file, 'utf8').trim();
    if (!/^[0-7]$/.test(value)) throw new Error('Invalid lifecycle phase.');
    return Number(value);
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error('Lifecycle phase is missing. Resume the Dex lifecycle before continuing.');
    throw error;
  }
}

function route(config, session) {
  const current = phase(session);
  const policyPhase = Math.min(current, PHASES.length - 1);
  const override = session.override;
  const clientRoute = session.client && config.client_routes?.[session.client];
  const configured = clientRoute || config.phases[policyPhase] || config.phases[PHASES[policyPhase]] || { model: config.default_model, fallbacks: [] };
  const choice = override && (override.scope === 'session' || override.phase === current || override.phase === policyPhase)
    ? override : configured;
  const ids = [choice.model, ...(choice.fallbacks || [])];
  const models = [...new Set(ids)].map(id => model(config, id));
  // session.context_limit is the compaction budget the client was launched with,
  // not a floor for later model choices. A smaller model stays selectable so an
  // exhausted provider never strands the session. The provider determines
  // whether the conversation fits the selected model.
  return { phase: current, models, effort: choice.effort ?? configured.effort, pinned: session.pinned_account };
}

// The smallest window across the configured route, handed to the client at
// launch as its compaction budget. Later route changes may select a smaller model.
function contextLimit(config, client) {
  const clientRoute = client && config.client_routes?.[client];
  const choices = clientRoute
    ? [clientRoute.model, ...(clientRoute.fallbacks || [])]
    : Object.values(config.phases).flatMap(value => [value.model, ...(value.fallbacks || [])]);
  if (!clientRoute && config.default_model) choices.push(config.default_model);
  if (!choices.length) throw new Error('Choose a default model with dx route configure.');
  return Math.min(...choices.map(id => model(config, id).context_window));
}

function usageWindows(account, target, now) {
  return account.usage && now - account.usage.observed_at < 120000 && !account.usage_error
    ? account.usage.windows.filter(window => (!window.model_pool || target.id.includes(window.model_pool)) && (!window.resets_at || window.resets_at > now)) : [];
}

// A provider rejection only proves that this account cannot serve the model
// over the protocol that was used. Requests CCR converts between wire formats
// (Codex Responses to Claude, Claude Messages to OpenAI) fail for their own
// reasons, so they cool down separately from native traffic on the same
// account and model.
function cooldownKey(target, protocol) {
  return protocol && protocol !== NATIVE_PROTOCOL[target.provider] ? `${target.id}@${protocol}` : target.id;
}

function blockers(account, target, now = Date.now(), protocol) {
  if (!account.enabled) return [{ reason: 'disabled' }];
  if (account.status === 'reauth-required') return [{ reason: 'reauth-required' }];
  if (account.model_ids && !account.model_ids.includes(target.id)) return [{ reason: 'model-unavailable' }];
  const result = usageWindows(account, target, now).filter(window => window.remaining_ratio === 0)
    .map(window => ({ reason: 'quota-exhausted', window: window.name, until: window.resets_at }));
  if (account.cooldown_until > now) result.push({ reason: account.cooldown_reason || 'cooldown', until: account.cooldown_until });
  const key = cooldownKey(target, protocol);
  if (account.model_cooldowns?.[key] > now) result.push({ reason: account.model_cooldown_reasons?.[key] || 'rate-limit', until: account.model_cooldowns[key] });
  return result;
}

function affinityKey(selection, protocol) {
  return state.hash(JSON.stringify([selection.phase, selection.models.map(target => target.id), selection.effort, selection.pinned, protocol]));
}

function candidates(items, selection, session, now = Date.now(), protocol) {
  const result = [];
  const models = [...selection.models];
  // Keep a working fallback until the phase or route changes, including resume.
  if (!selection.pinned && session.current_route === affinityKey(selection, protocol)) {
    const index = models.findIndex(target => target.id === session.current_model);
    if (index > 0) models.unshift(...models.splice(index, 1));
  }
  for (const target of models) {
    const windows = account => usageWindows(account, target, now);
    const available = items.filter(item => item.provider === target.provider
      && (!selection.pinned || item.id === selection.pinned)
      && !blockers(item, target, now, protocol).length);
    available.sort((a, b) => {
      const aRank = Number.isSafeInteger(a.rank) && a.rank > 0 ? a.rank : null;
      const bRank = Number.isSafeInteger(b.rank) && b.rank > 0 ? b.rank : null;
      if (aRank !== null || bRank !== null) {
        if (aRank === null) return 1;
        if (bRank === null) return -1;
        return aRank - bRank || (a.created_at || 0) - (b.created_at || 0);
      }
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

function retryIn(until, now = Date.now()) {
  const seconds = Math.max(1, Math.ceil((until - now) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.ceil(minutes / 60);
  return hours < 24 ? `${hours}h` : `${Math.ceil(hours / 24)}d`;
}

function unavailable(items, selection, now = Date.now(), protocol) {
  const clean = value => String(value).replace(/[\x00-\x1f\x7f-\x9f]/g, ' ');
  const labels = { disabled: 'disabled', 'reauth-required': 'login needs renewal', 'model-unavailable': 'model not available on this account',
    'rate-limit': 'rate limited', temporary: 'temporary provider error', 'connection-failed': 'provider connection failed',
    'refresh-unavailable': 'login refresh temporarily unavailable', cooldown: 'cooling down' };
  const waits = [], reasons = new Set(), eligibleBlocks = [];
  const summaries = (selection.pinned ? selection.models.slice(0, 1) : selection.models).map(target => {
    const pool = items.filter(item => item.provider === target.provider && (!selection.pinned || item.id === selection.pinned));
    const accounts = pool.map(account => {
      const blocked = blockers(account, target, now, protocol);
      if (!blocked.some(item => ['disabled', 'reauth-required', 'model-unavailable'].includes(item.reason))) eligibleBlocks.push(blocked);
      if (blocked.length && blocked.every(item => Number.isFinite(item.until) && item.until > now)) waits.push(Math.max(...blocked.map(item => item.until)));
      const explanation = blocked.map(item => {
        reasons.add(item.reason);
        const label = item.reason === 'quota-exhausted' ? `${clean(item.window)} quota exhausted` : labels[item.reason] || 'cooling down';
        return `${label}${item.until > now ? ` (${retryIn(item.until, now)})` : item.reason === 'quota-exhausted' ? ' (reset time unknown)' : ''}`;
      }).join(', ');
      return `${clean(account.name || account.id)}: ${explanation || 'available for retry'}`;
    });
    return `${clean(target.display_name || target.id)}: ${accounts.join('; ') || (selection.pinned ? 'pinned account cannot serve this model' : `no ${target.provider} accounts registered`)}.`;
  });
  const rateLimited = eligibleBlocks.length > 0 && eligibleBlocks.every(blocked => blocked.some(item => ['quota-exhausted', 'rate-limit'].includes(item.reason)));
  const retryAfter = waits.length ? Math.max(1, Math.ceil((Math.min(...waits) - now) / 1000)) : undefined;
  const advice = [];
  if (retryAfter) advice.push(`Retry in ${retryIn(now + retryAfter * 1000, now)}.`);
  if (selection.pinned) advice.push('Account pinning restricts failover. Use dx route unpin-account to restore it.');
  else {
    if (selection.models.length === 1) advice.push('No fallback models are configured for this route.');
    const otherProviders = new Set(items.filter(item => item.enabled && !selection.models.some(target => target.provider === item.provider)).map(item => item.provider));
    for (const provider of otherProviders) {
      advice.push(`No ${{ anthropic: 'Anthropic', openai: 'OpenAI' }[provider] || clean(provider)} fallback is configured for this route. Add one with dx route configure ... --fallback ${clean(provider)}/<model>.`);
    }
  }
  if (protocol && !selection.models.some(target => NATIVE_PROTOCOL[target.provider] === protocol)) {
    const provider = Object.keys(NATIVE_PROTOCOL).find(name => NATIVE_PROTOCOL[name] === protocol);
    advice.push(`Every model on this route needs CCR ${protocol} conversion. Add a ${provider} model with dx route configure ${provider}/<model> --phase <phase> or dx route use ${provider}/<model>${protocol === 'responses' ? ', or pick one in Codex with /model' : ''}.`);
  }
  if (reasons.has('reauth-required')) advice.push('Renew the affected login with dx account reauth <name>.');
  if (reasons.has('disabled')) advice.push('Enable an account with dx account enable <name>.');
  advice.push('Inspect dx accounts --live or select another model with dx route use.');
  const headline = rateLimited ? [`Subscription ${reasons.has('quota-exhausted') ? 'quota exhausted' : 'rate limit reached'} on this route.`] : [];
  return Object.assign(new Error([...headline, ...summaries, ...advice].join(' ')), {
    code: 'subscription_accounts_unavailable', status: rateLimited ? 429 : 503, type: rateLimited ? 'rate_limit_error' : 'api_error', retryAfter
  });
}

function failure(status, payload = {}, headers = {}, now = Date.now()) {
  if (status === 401) return { retry: true, reauth: true, reason: 'authentication' };
  if (status === 429) {
    const after = headers.get ? headers.get('retry-after') : headers['retry-after'];
    const delay = /^\d+(\.\d+)?$/.test(after || '') ? Number(after) * 1000 : Date.parse(after) - now;
    const reset = Number(payload?.error?.resets_at || payload?.resets_at) * 1000;
    // A 429 only establishes that this account cannot serve the requested model.
    // Shared exhausted quota windows exclude the account separately.
    return { retry: true, reason: 'rate-limit', until: Math.max(now + 1000, Number.isFinite(reset) && reset > now ? reset : now + (Number.isFinite(delay) ? delay : 60000)), modelOnly: true };
  }
  if ([408, 409, 500, 502, 503, 504, 529].includes(status)) return { retry: true, reason: 'temporary', until: now + 10000, modelOnly: true };
  return { retry: false, reason: status === 403 ? 'forbidden' : 'request-rejected' };
}

function validateRequest(body, target, protocol = 'messages') {
  if (protocol === 'responses') {
    if (!body || (!Array.isArray(body.input) && typeof body.input !== 'string')) throw new Error('A Responses request with input is required.');
    if (body.previous_response_id) throw new Error('Send the conversation input with each request so account failover can preserve it.');
  } else if (!body || !Array.isArray(body.messages)) throw new Error('A Messages request with a messages array is required.');
  const capabilities = target.capabilities || {};
  function visit(value) {
    if (Array.isArray(value)) { value.forEach(visit); return; }
    if (!value || typeof value !== 'object') return;
    if (['image', 'input_image'].includes(value.type) && capabilities.images !== true) throw new Error('The selected model has no verified image support.');
    if (['document', 'tool_reference', 'web_search_tool_result'].includes(value.type) && target.provider === 'openai') throw new Error(`The selected route cannot preserve ${value.type} content.`);
    Object.values(value).forEach(visit);
  }
  visit(protocol === 'responses' ? body.input : body.messages);
  if (body.tools?.length && capabilities.tools !== true) throw new Error('The selected model has no verified tool support.');
  // JSON bytes include tool schemas and encoded images, so they cannot enforce
  // a token budget. The HTTP reader bounds memory; the provider counts tokens.
}

module.exports = { PHASES, TERMINAL_PHASE, NATIVE_PROTOCOL, model, phase, route, contextLimit, affinityKey, cooldownKey, candidates, blockers, retryIn, unavailable, failure, validateRequest };
