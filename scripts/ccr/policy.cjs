'use strict';

const fs = require('node:fs');
const state = require('./state.cjs');
const { providerKind } = require('./accounts.cjs');

const PHASES = ['setup', 'plan', 'implement', 'review', 'verify', 'pr', 'complete'];
// The lifecycle writes 7 once Phase 6 has a verified terminal commit. The
// session keeps talking (final summary, follow-up questions) on the complete
// route; 7 is never configurable on its own.
const TERMINAL_PHASE = 7;
// A profile names the role a model plays — cheap, strong, frontier — so a
// route can be expressed once and re-pointed later. Resolution happens where a
// route is read, so a profile change applies to the next request without a
// restart, and the profile a value came from is recorded beside it for
// experiment data.
const PROFILE = /^@([a-z][a-z0-9_-]{0,31})$/;
function resolveProfiles(config, ids, path = 'route') {
  // `visiting` is the chain being walked, so two routes may name the same
  // profile; only a profile appearing in its own chain is a cycle.
  // A resolved profile remembers its answer, so a chain walked once is not
  // walked again — but the answer stored is the resolved model, never the
  // profile it was assigned, or a second reference to a nested profile would
  // hand back an unresolved name.
  const visiting = new Set(), answers = new Map();
  const resolve = id => {
    const match = typeof id === 'string' ? id.match(PROFILE) : null;
    if (!match) return id;
    if (visiting.has(id)) throw new Error(`Profile ${id} is part of a cycle.`);
    if (answers.has(id)) return answers.get(id);
    visiting.add(id);
    const assigned = config.profiles?.[match[1]];
    if (typeof assigned !== 'string') throw new Error(`Profile ${id.slice(1)} is not assigned a model. Set one with dx profile set ${match[1]} <provider/model>.`);
    const value = resolve(assigned);
    visiting.delete(id); answers.set(id, value);
    return value;
  };
  const resolved = ids.map(resolve);
  if (answers.size) {
    const existing = config.profile_bindings || {};
    for (const value of answers.keys()) { const name = value.match(PROFILE)[1]; existing[name] = (existing[name] || 0) + 1; }
    config.profile_bindings = existing;
  }
  return resolved;
}

// A Dex model ID is always `provider/name`. `name` is Dex's stable identifier,
// which is not necessarily the provider's: an aggregator's own IDs contain a
// vendor segment, so the upstream ID is carried separately on the model entry.
const PROVIDER_NAMES = ['anthropic', 'openai', 'openrouter'];
const MODEL = new RegExp(`^(${PROVIDER_NAMES.join('|')})\\/[A-Za-z0-9][A-Za-z0-9._:+-]*$`);
// Wire protocol each provider speaks without CCR conversion. A provider whose
// protocol no client speaks natively always routes through conversion, and so
// cools down separately from native traffic on the same account and model.
const NATIVE_PROTOCOL = { anthropic: 'messages', openai: 'responses', openrouter: 'chat' };
const PROVIDER_LABELS = { anthropic: 'Anthropic', openai: 'OpenAI', openrouter: 'OpenRouter' };
// Where each provider's traffic goes and which wire format it speaks. Adding a
// provider is an entry here plus a PROVIDERS entry in accounts.cjs; nothing in
// the request path branches on the provider name.
const PROVIDER_ENDPOINTS = {
  anthropic: { type: 'anthropic_messages', baseUrl: 'https://api.anthropic.com' },
  openai: { type: 'openai_responses', baseUrl: 'https://chatgpt.com/backend-api/codex' },
  openrouter: { type: 'openai_chat_completions', baseUrl: 'https://openrouter.ai/api/v1' }
};
// Reasoning effort arrives in the client's own dialect and does not survive
// conversion to chat completions. Dex's levels are translated once, for every
// provider on that wire format; a level above the format's top one clamps to it
// rather than being dropped, so asking for more reasoning never yields less.
const CHAT_EFFORT = { minimal: 'minimal', low: 'low', medium: 'medium', high: 'high', xhigh: 'high', max: 'high' };
function chatReasoning(body) {
  const requested = body?.output_config?.effort || body?.reasoning?.effort;
  return typeof requested === 'string' ? CHAT_EFFORT[requested] : undefined;
}

function model(config, id) {
  if (typeof id === 'string' && PROFILE.test(id)) throw new Error('A route may only name a profile through dx route configure; other commands need the provider/model ID.');
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

// Review waves take turns over the models on their route, so consecutive clean
// passes come from different reviewers — the spec's answer to raising quality
// without raising the count. The rotation is a function of the wave index
// alone: deterministic, observable in telemetry, and identical on resume.
function rotateForWave(models, wave) {
  if (!models.length) return models;
  const shift = Number.isInteger(wave) && wave > 0 ? wave % models.length : 0;
  return shift ? [...models.slice(shift), ...models.slice(0, shift)] : models;
}

// An explicitly chosen model still degrades, but only within the provider it
// named: choosing a model chooses its provider too, so a failure there must not
// quietly move the work to a different one — a different bill, a different
// privacy boundary, a different model family. The order comes from the
// automatic route, so Opus falls to Fable, Sol to Astra, GLM to Qwen, and the
// last model of a provider simply stops.
function explicitChain(routeModels, target) {
  const index = routeModels.findIndex(item => item.id === target.id);
  if (index < 0) return [target];
  return routeModels.slice(index).filter(item => item.provider === target.provider);
}

// The models a native client offers in its own picker, primary first. Null when
// that client has no route of its own.
function clientModels(config, client) {
  const route = client && config.client_routes?.[client];
  if (!route?.model) return null;
  const ids = resolveProfiles(config, [route.model, ...(route.fallbacks || [])]);
  return { models: [...new Set(ids)].map(id => model(config, id)), effort: route.effort };
}

function route(config, session) {
  const current = phase(session);
  const policyPhase = Math.min(current, PHASES.length - 1);
  const override = session.override;
  // A client route names the models that client offers in its own picker; it
  // does not narrow the automatic route. Choosing the automatic option in a
  // native client means the whole pipeline, across every provider, the same as
  // a lifecycle gets — a client that wanted only its own models would pick one.
  const configured = config.phases[policyPhase] || config.phases[PHASES[policyPhase]] || { model: config.default_model, fallbacks: [] };
  const choice = override && (override.scope === 'session' || override.phase === current || override.phase === policyPhase)
    ? override : configured;
  // Profiles resolve here, where the route is read, so re-pointing one applies
  // to the next request with no restart. The config object is the running
  // service's own copy, so the binding counts it accumulates are transient.
  const ids = resolveProfiles(config, [choice.model, ...(choice.fallbacks || [])]);
  const models = rotateForWave([...new Set(ids)].map(id => model(config, id)), session.review_wave);
  // session.context_limit is the compaction budget the client was launched with,
  // not a floor for later model choices. A smaller model stays selectable so an
  // exhausted provider never strands the session. The provider determines
  // whether the conversation fits the selected model.
  return { phase: current, models, effort: choice.effort ?? configured.effort, pinned: session.pinned_account };
}

function modelCapacity(target) {
  const maximum = target.max_context_window;
  if (maximum !== undefined && (!Number.isSafeInteger(maximum) || maximum < target.context_window || maximum > 4000000)) {
    throw new Error(`Invalid maximum context window for ${target.id}. Refresh model metadata.`);
  }
  return maximum ?? target.context_window;
}

// The client default is not the provider maximum. Legacy entries remain bounded
// by their recorded window until discovery supplies an advertised maximum.
// The budget a client launches with has to hold every model that client can
// reach: its own, and the automatic route it can also choose.
function contextLimit(config, client) {
  const clientRoute = client && config.client_routes?.[client];
  const choices = [...(clientRoute ? [clientRoute.model, ...(clientRoute.fallbacks || [])] : []),
    ...Object.values(config.phases).flatMap(value => [value.model, ...(value.fallbacks || [])])];
  if (config.default_model) choices.push(config.default_model);
  if (!choices.length) throw new Error('Choose a default model with dx route configure.');
  const targets = [...new Set(resolveProfiles(config, choices))].map(id => model(config, id));
  const budget = config.context_budget;
  if (budget !== undefined && (!Number.isSafeInteger(budget) || budget < 8192 || budget > 4000000)) throw new Error('Context budget must be an integer between 8192 and 4000000 tokens.');
  for (const target of targets) {
    if (budget !== undefined && budget > modelCapacity(target)) throw new Error(`Context budget ${budget} exceeds ${target.id}'s advertised capacity ${modelCapacity(target)}. Refresh metadata or remove this model from the route.`);
  }
  return Math.min(budget ?? 800000, ...targets.map(modelCapacity));
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
      const ranked = byRank(a, b);
      if (ranked !== 0) return ranked;
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

// Ranked accounts come first in rank order; two unranked accounts compare equal
// so callers can add their own tie-break (affinity, registration order).
function byRank(a, b) {
  const aRank = Number.isSafeInteger(a.rank) && a.rank > 0 ? a.rank : null;
  const bRank = Number.isSafeInteger(b.rank) && b.rank > 0 ? b.rank : null;
  if (aRank === null && bRank === null) return 0;
  if (aRank === null) return 1;
  if (bRank === null) return -1;
  return aRank - bRank || (a.created_at || 0) - (b.created_at || 0);
}
function rankOrder(items) {
  return [...items].sort((a, b) => byRank(a, b) || (a.created_at || 0) - (b.created_at || 0));
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
    'refresh-unavailable': 'login refresh temporarily unavailable', 'terms-required': 'accept updated terms in claude.ai', cooldown: 'cooling down',
    'payment-required': 'provider credit exhausted', forbidden: 'not permitted by the provider',
    'budget-exceeded': 'spend limit reached' };
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
  const termsRequired = reasons.has('terms-required') && eligibleBlocks.length > 0
    && eligibleBlocks.every(blocked => blocked.some(item => ['terms-required', 'quota-exhausted', 'rate-limit'].includes(item.reason)));
  const retryAfter = waits.length ? Math.max(1, Math.ceil((Math.min(...waits) - now) / 1000)) : undefined;
  const advice = [];
  if (retryAfter) advice.push(`Retry in ${retryIn(now + retryAfter * 1000, now)}.`);
  if (selection.pinned) advice.push('Account pinning restricts failover. Use dx route unpin-account to restore it.');
  else {
    if (selection.models.length === 1) advice.push('No fallback models are configured for this route.');
    const otherProviders = new Set(items.filter(item => item.enabled && !selection.models.some(target => target.provider === item.provider)).map(item => item.provider));
    for (const provider of otherProviders) {
      advice.push(`No ${PROVIDER_LABELS[provider] || clean(provider)} fallback is configured for this route. Add one with dx route configure ... --fallback ${clean(provider)}/<model>.`);
    }
  }
  if (protocol && !selection.models.some(target => NATIVE_PROTOCOL[target.provider] === protocol)) {
    const provider = Object.keys(NATIVE_PROTOCOL).find(name => NATIVE_PROTOCOL[name] === protocol);
    const label = PROVIDER_LABELS[provider] || provider;
    advice.push(`Every model on this route needs CCR ${protocol} conversion. Add ${/^[AEIOU]/i.test(label) ? 'an' : 'a'} ${label} model with dx route configure ${provider}/<model> --phase <phase> or dx route use ${provider}/<model>${protocol === 'responses' ? ', or pick one in Codex with /model' : ''}.`);
  }
  if (reasons.has('payment-required')) advice.push('A metered account is out of credit. Top it up, or route this phase to a subscription model with dx route configure <provider/model> --phase <phase>.');
  if (reasons.has('budget-exceeded')) advice.push('A spend limit was reached on the provider, not in Dex. Raise it there, wait for it to reset, or route this phase to another model.');
  if (reasons.has('forbidden')) advice.push('The provider refused this model for this account. Check the provider\'s own model permissions or guardrails, then retry.');
  if (reasons.has('reauth-required')) advice.push('Renew the affected login with dx account reauth <name>.');
  if (reasons.has('terms-required')) advice.push('Sign in to claude.ai with the affected account and accept the updated Consumer Terms and Privacy Policy, then retry after the short account cooldown. Use dx account show <name> to check its login identity.');
  if (reasons.has('disabled')) advice.push('Enable an account with dx account enable <name>.');
  advice.push('Inspect dx accounts --live or select another model with dx route use.');
  // A metered provider has no subscription to name, so only a route that can
  // reach one describes the limit as a subscription's.
  const problem = reasons.has('quota-exhausted') ? 'quota exhausted' : 'rate limit reached';
  const subscribed = selection.models.some(target => providerKind(target.provider) === 'subscription');
  const headline = rateLimited ? [subscribed ? `Subscription ${problem} on this route.` : `${problem[0].toUpperCase()}${problem.slice(1)} on this route.`] : [];
  // Nothing transient is in the way: either no account serves this route at
  // all, or every one of them is disabled, needs a new login, or cannot serve
  // the model. None of that resolves by asking again, and a 5xx invites the
  // client to keep asking — Claude Code spends ten backed-off retries on it
  // and truncates the one line that says what to fix. Report it the way the
  // terms case already does, as the caller's problem, so it surfaces at once.
  const permanent = !eligibleBlocks.length && !retryAfter;
  return Object.assign(new Error([...headline, ...summaries, ...advice].join(' ')), {
    code: 'subscription_accounts_unavailable', status: termsRequired || permanent ? 400 : rateLimited ? 429 : 503,
    type: termsRequired || permanent ? 'invalid_request_error' : rateLimited ? 'rate_limit_error' : 'api_error', retryAfter
  });
}

// A provider says "you have spent too much" in prose, so this reads prose. It
// is deliberately narrow: a budget or spend limit that has been reached or
// exceeded. Anything it does not recognise stays a per-model refusal, which is
// the safer mistake — a short cooldown on one model rather than a long one on
// the account.
function budgetExceeded(payload) {
  const message = [payload?.error?.message, payload?.message, payload?.error?.metadata?.raw]
    .find(value => typeof value === 'string') || '';
  return /\b(budget|spend|credits?|quotas?|limits?)\b/i.test(message)
    && /\b(exceed|exhaust|reach|insufficient|over)\w*/i.test(message);
}

// When a spend cap comes back, if the provider says so. A budget refusal lasts
// until then: waiting less only buys another refusal, and a fixed interval
// either retries pointlessly or idles an account that has already reset. The
// wait is capped at a day so a long cap is still probed occasionally — the
// limit may have been raised in the meantime, and one refused request a day
// costs nothing.
const MAX_BUDGET_WAIT = 86400000;
function spendResetAt(account, now = Date.now()) {
  const resets = (account?.usage?.windows || [])
    .filter(window => window.name === 'spend-limit' && Number.isFinite(window.resets_at) && window.resets_at > now)
    .map(window => window.resets_at);
  return resets.length ? Math.min(Math.min(...resets), now + MAX_BUDGET_WAIT) : null;
}

function failure(status, payload = {}, headers = {}, now = Date.now()) {
  if (status === 401) return { retry: true, reauth: true, reason: 'authentication' };
  // Payment Required is the metered equivalent of an exhausted quota: this
  // account cannot serve anything until it is topped up. It stops the account,
  // not the request, so the route falls through to whatever else can serve it
  // rather than returning the provider's own error to the client.
  if (status === 402) return { retry: true, reason: 'payment-required', until: now + 1800000 };
  // A refusal for spending too much is not about permission: it applies to
  // every model the budget covers, so retrying the next one only buys another
  // refusal. It stops the account for as long as a 402 does. Anything else
  // forbidden — a guardrail, a key scope — is about this model, and cools
  // briefly because the cause is usually config someone is about to change.
  if (status === 403) {
    return budgetExceeded(payload)
      ? { retry: true, reason: 'budget-exceeded', until: now + 1800000 }
      : { retry: true, reason: 'forbidden', until: now + 300000, modelOnly: true };
  }
  if (status === 429) {
    const after = headers.get ? headers.get('retry-after') : headers['retry-after'];
    const delay = /^\d+(\.\d+)?$/.test(after || '') ? Number(after) * 1000 : Date.parse(after) - now;
    const reset = Number(payload?.error?.resets_at || payload?.resets_at) * 1000;
    // A 429 only establishes that this account cannot serve the requested model.
    // Shared exhausted quota windows exclude the account separately.
    return { retry: true, reason: 'rate-limit', until: Math.max(now + 1000, Number.isFinite(reset) && reset > now ? reset : now + (Number.isFinite(delay) ? delay : 60000)), modelOnly: true };
  }
  if ([408, 409, 500, 502, 503, 504, 529].includes(status)) return { retry: true, reason: 'temporary', until: now + 10000, modelOnly: true };
  return { retry: false, reason: 'request-rejected' };
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
    // A tool_reference is not in this list: it pins a deferred tool definition
    // that only Anthropic reads, and the schema itself reaches every provider
    // in the tools array, so prepareHistory drops the block instead of failing
    // the request. These two carry content nothing downstream can reconstruct.
    if (['document', 'web_search_tool_result'].includes(value.type) && target.provider === 'openai') throw new Error(`The selected route cannot preserve ${value.type} content.`);
    Object.values(value).forEach(visit);
  }
  visit(protocol === 'responses' ? body.input : body.messages);
  if (body.tools?.length && capabilities.tools !== true) throw new Error('The selected model has no verified tool support.');
  // JSON bytes include tool schemas and encoded images, so they cannot enforce
  // a token budget. The HTTP reader bounds memory; the provider counts tokens.
}

module.exports = { PHASES, TERMINAL_PHASE, NATIVE_PROTOCOL, budgetExceeded, spendResetAt, MAX_BUDGET_WAIT, clientModels, explicitChain, PROVIDER_NAMES, PROVIDER_LABELS, PROVIDER_ENDPOINTS, PROFILE, CHAT_EFFORT, chatReasoning, resolveProfiles, rotateForWave, MODEL, model, modelCapacity, phase, route, contextLimit, affinityKey, cooldownKey, candidates, byRank, rankOrder, blockers, retryIn, unavailable, failure, validateRequest };
