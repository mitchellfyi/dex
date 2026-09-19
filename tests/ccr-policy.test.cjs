'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const policy = require('../scripts/ccr/policy.cjs');
const models = [
  { id: 'anthropic/a', provider: 'anthropic', context_window: 200000, capabilities: { tools: true, images: true } },
  { id: 'openai/b', provider: 'openai', context_window: 128000, capabilities: { tools: true } }
];
const config = { models, default_model: models[0].id, phases: { 2: { model: models[1].id, fallbacks: [models[0].id] } } };
test('phase routing preserves the configured fallback order', () => {
  assert.deepEqual(policy.route(config, { fixed_phase: 2 }).models.map(x => x.id), ['openai/b', 'anthropic/a']);
});
test('native clients can use their own configured route and context budget', () => {
  const configured = { ...config, client_routes: { codex: { model: 'openai/b', fallbacks: ['anthropic/a'] } } };
  assert.deepEqual(policy.route(configured, { client: 'codex' }).models.map(x => x.id), ['openai/b', 'anthropic/a']);
  assert.equal(policy.contextLimit(configured, 'codex'), 128000);
  assert.equal(policy.route(configured, { client: 'claude' }).models[0].id, 'anthropic/a');
});
test('phase override expires while session override remains', () => {
  const override = { model: 'anthropic/a', scope: 'phase', phase: 1 };
  assert.equal(policy.route(config, { fixed_phase: 2, override }).models[0].id, 'openai/b');
  override.scope = 'session';
  assert.equal(policy.route(config, { fixed_phase: 2, override }).models[0].id, 'anthropic/a');
});
test('the terminal phase keeps the complete route and cannot be configured', () => {
  const terminal = { ...config, phases: { ...config.phases, 6: { model: models[1].id, fallbacks: [] } } };
  assert.equal(policy.route(terminal, { fixed_phase: 7 }).phase, 7);
  assert.deepEqual(policy.route(terminal, { fixed_phase: 7 }).models.map(x => x.id), ['openai/b']);
  assert.equal(policy.route(terminal, { fixed_phase: 7, override: { model: 'anthropic/a', scope: 'phase', phase: 7 } }).models[0].id, 'anthropic/a');
  assert.equal(policy.route(terminal, { fixed_phase: 7, override: { model: 'anthropic/a', scope: 'phase', phase: 6 } }).models[0].id, 'anthropic/a');
  assert.throws(() => policy.route(terminal, { fixed_phase: 8 }), /Invalid fixed phase/);
  assert.equal(policy.PHASES.length, 7);
});
test('phase files accept the terminal marker and reject anything else', () => {
  const fs = require('node:fs'); const os = require('node:os'); const path = require('node:path');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-phase-'));
  const phase_file = path.join(directory, 'lifecycle.phase');
  try {
    for (const value of ['0', '6', '7']) { fs.writeFileSync(phase_file, `${value}\n`, { mode: 0o600 }); assert.equal(policy.phase({ phase_file }), Number(value)); }
    for (const value of ['8', 'done', '']) { fs.writeFileSync(phase_file, value, { mode: 0o600 }); assert.throws(() => policy.phase({ phase_file }), /Invalid lifecycle phase/); }
    fs.unlinkSync(phase_file);
    assert.throws(() => policy.phase({ phase_file }), /Lifecycle phase is missing/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
test('context budget includes fallback models', () => assert.equal(policy.contextLimit(config), 128000));
test('long-context routes distinguish advertised maximum from client default and use an explicit budget', () => {
  const long = { default_model: 'anthropic/a', context_budget: 800000, phases: { 0: { model: 'anthropic/a', fallbacks: ['openai/b'] } }, models: [
    { ...models[0], context_window: 1000000, max_context_window: 1000000 },
    { ...models[1], context_window: 272000, max_context_window: 872000 }
  ] };
  assert.equal(policy.contextLimit(long), 800000);
  assert.equal(policy.contextLimit({ ...long, context_budget: undefined }), 800000);
  for (const context_budget of [0, -1, '800000', 8000, 872001, 5000000]) {
    assert.throws(() => policy.contextLimit({ ...long, context_budget }), /context|budget/i);
  }
  assert.throws(() => policy.contextLimit({ ...long, models: [long.models[0], models[1]] }), /openai\/b/);
});
test('a smaller context model can join a running session without treating JSON bytes as tokens', () => {
  // The session was launched at a 200k budget; the phase route and an override both bring in a 128k model.
  assert.deepEqual(policy.route(config, { fixed_phase: 2, context_limit: 200000 }).models.map(x => x.id), ['openai/b', 'anthropic/a']);
  assert.deepEqual(policy.route(config, { fixed_phase: 0, context_limit: 200000, override: { model: 'openai/b', scope: 'session' } }).models.map(x => x.id), ['openai/b']);
  const small = { ...models[1], context_window: 8192, display_name: 'Small' };
  const oversized = { messages: [{ role: 'user', content: 'x'.repeat(8192 * 4) }] };
  assert.doesNotThrow(() => policy.validateRequest(oversized, small));
  assert.doesNotThrow(() => policy.validateRequest({ messages: [{ role: 'user', content: 'hello' }] }, small));
  assert.doesNotThrow(() => policy.validateRequest(oversized, models[0]));
  assert.doesNotThrow(() => policy.validateRequest({ input: 'x'.repeat(8192 * 4) }, small, 'responses'));
});
test('invalid models cannot become filesystem paths or unknown routes', () => {
  for (const id of ['', '../secret', 'other/model', 'openai/unknown']) assert.throws(() => policy.model(config, id));
});
test('same model rotates accounts before another model and respects cooldowns', () => {
  const items = [{ id: 'a', provider: 'anthropic', enabled: true }, { id: 'b', provider: 'anthropic', enabled: true }, { id: 'c', provider: 'openai', enabled: true }];
  const selected = { models };
  assert.deepEqual(policy.candidates(items, selected, { current_account: 'b' }).map(x => x.account.id), ['b', 'a', 'c']);
  items[1].cooldown_until = 2000;
  assert.deepEqual(policy.candidates(items, selected, {}, 1000).map(x => x.account.id), ['a', 'c']);
});
test('explicit account ranks take precedence over affinity and quota headroom', () => {
  const usage = remaining_ratio => ({ observed_at: 1000, windows: [{ name: 'weekly', remaining_ratio }] });
  const items = [
    { id: 'a', provider: 'anthropic', enabled: true, rank: 1, created_at: 2, usage: usage(0.1) },
    { id: 'b', provider: 'anthropic', enabled: true, rank: 2, created_at: 1, usage: usage(0.9) },
    { id: 'c', provider: 'openai', enabled: true, rank: 3, created_at: 0, usage: usage(1) }
  ];
  assert.deepEqual(policy.candidates(items, { models }, { current_account: 'b' }, 1000).map(x => x.account.id), ['a', 'b', 'c']);
  items[0].cooldown_until = 2000;
  assert.deepEqual(policy.candidates(items, { models }, { current_account: 'b' }, 1000).map(x => x.account.id), ['b', 'c']);
});
test('pinning never silently uses another account', () => {
  assert.deepEqual(policy.candidates([{ id: 'a', provider: 'anthropic', enabled: true }], { models, pinned: 'b' }, {}), []);
});
test('a working fallback stays first only for the same phase, route and protocol', () => {
  const items = [{ id: 'a', provider: 'anthropic', enabled: true }, { id: 'b', provider: 'openai', enabled: true }];
  const selection = { phase: 2, models, effort: 'xhigh' };
  const session = { current_model: 'openai/b', current_route: policy.affinityKey(selection, 'messages') };
  const order = (choice, saved = session, protocol = 'messages') => policy.candidates(items, choice, saved, 1000, protocol).map(item => item.model.id);
  assert.deepEqual(order(selection), ['openai/b', 'anthropic/a']);
  for (const change of [{ phase: 3 }, { effort: 'high' }, { models: [models[0]] }, { pinned: 'a' }]) {
    assert.equal(order({ ...selection, ...change })[0], 'anthropic/a');
  }
  assert.equal(order(selection, {}, 'messages')[0], 'anthropic/a');
  assert.equal(order(selection, session, 'responses')[0], 'anthropic/a');
  items[1].cooldown_until = 2000;
  assert.deepEqual(order(selection), ['anthropic/a']);
});
test('manual model overrides inherit the configured phase or client effort', () => {
  const configured = { ...config, phases: { 2: { model: 'anthropic/a', effort: 'xhigh' } }, client_routes: { codex: { model: 'openai/b', effort: 'high' } } };
  const session = { fixed_phase: 2, override: { model: 'openai/b', scope: 'session' } };
  assert.equal(policy.route(configured, session).effort, 'xhigh');
  assert.equal(policy.route(configured, { ...session, client: 'codex' }).effort, 'high');
});
test('auth, quota, temporary failures and malformed requests are distinct', () => {
  assert.equal(policy.failure(401).reauth, true);
  assert.equal(policy.failure(429, {}, { 'retry-after': '120' }, 1000).until, 121000);
  assert.equal(policy.failure(503).retry, true);
  for (const code of [408, 409, 500, 502, 503, 504, 529]) assert.equal(policy.failure(code).modelOnly, true);
  // A request the provider rejects on its own terms is not failed over; a
  // provider refusing to serve this account is (402/403 have their own test).
  for (const code of [400, 404, 422]) assert.equal(policy.failure(code).retry, false);
});
test('model-only quota rejection does not exhaust the whole account', () => {
  assert.equal(policy.failure(429, { error: { type: 'model_rate_limit' } }).modelOnly, true);
  assert.equal(policy.failure(429, { error: { type: 'rate_limit_error' } }).modelOnly, true);
  assert.equal(policy.failure(429).modelOnly, true);
  assert.equal(policy.failure(429, null).modelOnly, true);
});
test('a model quota or cooldown leaves another model on the same account eligible', () => {
  const fallback = { ...models[0], id: 'anthropic/fallback' };
  const account = { id: 'one', provider: 'anthropic', enabled: true, usage: { observed_at: 1000, windows: [
    { name: 'primary', model_pool: 'anthropic/a', remaining_ratio: 0, resets_at: 61000 }
  ] } };
  const selected = { models: [models[0], fallback] };
  assert.deepEqual(policy.candidates([account], selected, {}, 1000).map(item => item.model.id), ['anthropic/fallback']);
  account.usage.windows = [];
  account.model_cooldowns = { 'anthropic/a': 61000 };
  assert.deepEqual(policy.candidates([account], selected, {}, 1000).map(item => item.model.id), ['anthropic/fallback']);
  account.usage.windows = [{ name: '5h', remaining_ratio: 0, resets_at: 61000 }];
  assert.deepEqual(policy.candidates([account], selected, {}, 1000), []);
});
test('converted-protocol failures cool down separately from native traffic', () => {
  assert.equal(policy.cooldownKey(models[0], 'messages'), 'anthropic/a');
  assert.equal(policy.cooldownKey(models[0], undefined), 'anthropic/a');
  assert.equal(policy.cooldownKey(models[0], 'responses'), 'anthropic/a@responses');
  assert.equal(policy.cooldownKey(models[1], 'responses'), 'openai/b');
  assert.equal(policy.cooldownKey(models[1], 'messages'), 'openai/b@messages');
  const account = { id: 'one', provider: 'anthropic', enabled: true, model_cooldowns: { 'anthropic/a@responses': 61000 }, model_cooldown_reasons: { 'anthropic/a@responses': 'rate-limit' } };
  assert.deepEqual(policy.blockers(account, models[0], 1000), []);
  assert.deepEqual(policy.blockers(account, models[0], 1000, 'messages'), []);
  assert.deepEqual(policy.blockers(account, models[0], 1000, 'responses'), [{ reason: 'rate-limit', until: 61000 }]);
  assert.deepEqual(policy.candidates([account], { models: [models[0]] }, {}, 1000, 'messages').map(item => item.account.id), ['one']);
  assert.deepEqual(policy.candidates([account], { models: [models[0]] }, {}, 1000, 'responses'), []);
  const error = policy.unavailable([account], { models: [models[0]] }, 1000, 'responses');
  assert.match(error.message, /rate limited \(1m\)/);
  assert.match(error.message, /needs CCR responses conversion/);
  assert.match(error.message, /dx route configure openai\/<model>/);
  assert.match(error.message, /pick one in Codex with \/model/);
  assert.doesNotMatch(policy.unavailable([account], { models }, 1000, 'responses').message, /conversion/);
  assert.doesNotMatch(policy.unavailable([account], { models: [models[0]] }, 1000).message, /conversion/);
  const converted = policy.unavailable([{ id: 'c', provider: 'openai', enabled: true, cooldown_until: 61000 }], { models: [models[1]] }, 1000, 'messages');
  assert.match(converted.message, /needs CCR messages conversion/);
  assert.doesNotMatch(converted.message, /\/model/);
});
test('unavailable errors identify each model and the earliest account that can recover', () => {
  const fallback = { ...models[0], id: 'anthropic/fallback', display_name: 'Fallback' };
  const items = [
    { id: 'one', name: 'Main', provider: 'anthropic', enabled: true, model_cooldowns: { 'anthropic/a': 61000, 'anthropic/fallback': 31000 } },
    { id: 'two', name: 'Backup', provider: 'anthropic', enabled: true, cooldown_until: 11000, cooldown_reason: 'temporary' }
  ];
  const error = policy.unavailable(items, { models: [models[0], fallback] }, 1000);
  assert.equal(error.retryAfter, 10);
  assert.match(error.message, /anthropic\/a: Main: rate limited \(1m\)/);
  assert.match(error.message, /Fallback: Main: rate limited \(30s\)/);
  assert.match(error.message, /Backup: temporary provider error \(10s\)/);
  assert.match(error.message, /Retry in 10s/);
  assert.doesNotMatch(error.message, /reauth|No fallback/);
});
test('retry waits for every exhausted window and cooldown on an account', () => {
  const account = { id: 'one', provider: 'anthropic', enabled: true, cooldown_until: 61000, usage: { observed_at: 1000, windows: [
    { name: '5h', remaining_ratio: 0, resets_at: 11000 }, { name: 'weekly', remaining_ratio: 0, resets_at: 31000 }
  ] } };
  assert.equal(policy.unavailable([account], { models }, 1000).retryAfter, 60);
  account.usage.windows[1].resets_at = null;
  const unknown = policy.unavailable([account], { models }, 1000);
  assert.equal(unknown.retryAfter, undefined);
  assert.match(unknown.message, /weekly quota exhausted \(reset time unknown\)/);
  assert.doesNotMatch(unknown.message, /Retry in/);
});
test('weekly exhaustion is a rate limit with a readable retry and missing-provider fallback advice', () => {
  const fallback = { ...models[0], id: 'anthropic/fallback' };
  const items = [
    { id: 'one', provider: 'anthropic', enabled: true, model_cooldowns: { 'anthropic/a': 22000 }, usage: { observed_at: 1000, windows: [
      { name: 'weekly', remaining_ratio: 0, resets_at: 141922000 }
    ] } },
    { id: 'two', provider: 'anthropic', enabled: true, usage: { observed_at: 1000, windows: [
      { name: 'weekly', remaining_ratio: 0, resets_at: 345601000 }
    ] } },
    { id: 'three', provider: 'openai', enabled: true }
  ];
  const error = policy.unavailable(items, { models: [models[0], fallback] }, 1000);
  assert.equal(error.status, 429);
  assert.equal(error.type, 'rate_limit_error');
  assert.equal(error.code, 'subscription_accounts_unavailable');
  assert.equal(error.retryAfter, 141921);
  assert.match(error.message, /^Subscription quota exhausted on this route\./);
  assert.match(error.message, /Retry in 2d\./);
  assert.match(error.message, /No OpenAI fallback is configured for this route/);
  assert.match(error.message, /dx route configure.*--fallback openai\/<model>/);
  assert.doesNotMatch(error.message, /141921s|temporary|server-side|reauth/);
  const pinned = policy.unavailable(items, { models, pinned: 'one' }, 1000);
  assert.match(pinned.message, /dx route unpin-account/);
  assert.doesNotMatch(pinned.message, /No OpenAI fallback/);
});
test('quota errors retain their classification without a known reset time', () => {
  const account = { id: 'one', provider: 'anthropic', enabled: true, usage: { observed_at: 1000, windows: [
    { name: 'weekly', remaining_ratio: 0, resets_at: null }
  ] } };
  const error = policy.unavailable([account], { models: [models[0]] }, 1000);
  assert.equal(error.status, 429);
  assert.equal(error.type, 'rate_limit_error');
  assert.equal(error.retryAfter, undefined);
  assert.doesNotMatch(error.message, /Retry in/);
});
test('unavailable status distinguishes exhausted capacity from a recoverable provider failure', () => {
  const limited = { id: 'one', provider: 'anthropic', enabled: true, model_cooldowns: { 'anthropic/a': 61000 } };
  const temporary = { id: 'two', provider: 'anthropic', enabled: true, cooldown_until: 11000, cooldown_reason: 'temporary' };
  const selected = { models: [models[0]] };
  for (const extra of [{ ...temporary, enabled: false }, { ...temporary, status: 'reauth-required' }, { ...temporary, model_ids: [] }]) {
    const error = policy.unavailable([limited, extra], selected, 1000);
    assert.equal(error.status, 429);
    assert.equal(error.type, 'rate_limit_error');
  }
  for (const items of [[limited, temporary], [temporary], [], [{ ...temporary, enabled: false }]]) {
    const error = policy.unavailable(items, selected, 1000);
    assert.equal(error.status, 503);
    assert.equal(error.type, 'api_error');
    assert.doesNotMatch(error.message, /^Subscription (quota|rate limit)/);
  }
  const error = policy.unavailable([limited], selected, 1000);
  assert.match(error.message, /^Subscription rate limit reached on this route\./);
});
test('terms acceptance remains actionable when the other provider has exhausted its quota', () => {
  const terms = { id: 'one', name: 'New Claude account', provider: 'anthropic', enabled: true, cooldown_until: 61000, cooldown_reason: 'terms-required' };
  const exhausted = { id: 'two', provider: 'openai', enabled: true, usage: { observed_at: 1000, windows: [
    { name: 'weekly', remaining_ratio: 0, resets_at: 86401000 }
  ] } };
  const error = policy.unavailable([terms, exhausted], { models }, 1000);
  assert.equal(error.status, 400);
  assert.equal(error.type, 'invalid_request_error');
  assert.match(error.message, /New Claude account: accept updated terms in claude\.ai/);
  assert.match(error.message, /weekly quota exhausted/);
  assert.match(error.message, /dx account show <name>/);
  assert.equal(error.retryAfter, 60);
  assert.deepEqual(policy.candidates([terms, exhausted], { models }, {}, 61001).map(item => item.account.id), ['one']);
});
test('login, disabled, missing models and strict pins have actionable explanations', () => {
  const account = { id: 'one', name: 'Main\u001b[2J', provider: 'anthropic', enabled: true, status: 'reauth-required', cooldown_until: 61000 };
  let error = policy.unavailable([account], { models: [models[0]] }, 1000);
  assert.match(error.message, /login needs renewal/);
  assert.match(error.message, /dx account reauth <name>/);
  assert.match(error.message, /No fallback models/);
  assert.equal(error.retryAfter, undefined);
  assert.equal(error.message.includes('\u001b'), false);
  account.enabled = false;
  error = policy.unavailable([account], { models }, 1000);
  assert.match(error.message, /disabled/);
  assert.match(error.message, /dx account enable <name>/);
  assert.doesNotMatch(error.message, /reauth/);
  account.enabled = true; account.status = 'ready'; account.model_ids = [];
  assert.match(policy.unavailable([account], { models }, 1000).message, /model not available on this account/);
  error = policy.unavailable([account], { models, pinned: 'missing' }, 1000);
  assert.match(error.message, /pinned account cannot serve this model/);
  assert.match(error.message, /dx route unpin-account/);
  assert.doesNotMatch(error.message, /openai\/b/);
});
test('unsupported content is rejected before routing', () => {
  assert.throws(() => policy.validateRequest({ messages: [{ role: 'user', content: [{ type: 'image' }] }] }, models[1]), /image/);
  assert.doesNotThrow(() => policy.validateRequest({ messages: [{ role: 'user', content: 'hello' }], tools: [{ name: 'Read' }] }, models[1]));
});

test('a metered route reports its limit without calling it a subscription', () => {
  const glm = { id: 'openrouter/glm-5.3', provider: 'openrouter', display_name: 'GLM 5.3', context_window: 1048576 };
  const opus = { id: 'anthropic/claude-opus-5', provider: 'anthropic', display_name: 'Opus 5', context_window: 200000 };
  const limited = provider => ({ id: provider, name: provider, provider, enabled: true, created_at: 1, cooldown_until: 2000, cooldown_reason: 'rate-limit' });
  const metered = policy.unavailable([limited('openrouter')], { phase: 2, models: [glm] }, 1000, 'messages');
  assert.match(metered.message, /^Rate limit reached on this route\./);
  assert.doesNotMatch(metered.message, /Subscription/);
  // A route that can still reach a subscription keeps describing it as one.
  const mixed = policy.unavailable([limited('openrouter'), limited('anthropic')], { phase: 2, models: [glm, opus] }, 1000, 'messages');
  assert.match(mixed.message, /^Subscription rate limit reached on this route\./);
  // The advice that names another provider reads as a sentence.
  assert.match(metered.message, /Add an Anthropic model with dx route configure anthropic\/<model>/);
  assert.doesNotMatch(metered.message, /Add a anthropic/);
});

test('a profile resolves where the route is read, so re-pointing it needs no restart', () => {
  const models = [
    { id: 'openrouter/glm-5.3', provider: 'openrouter', context_window: 200000 },
    { id: 'anthropic/claude-fable-5-1', provider: 'anthropic', context_window: 200000 },
    { id: 'anthropic/claude-opus-5', provider: 'anthropic', context_window: 200000 }
  ];
  const config = { models, profiles: { cheap: 'openrouter/glm-5.3', strong: '@near_frontier', near_frontier: 'anthropic/claude-fable-5-1' },
    phases: { 2: { model: '@cheap', fallbacks: ['@strong'] }, 3: { model: '@strong' } }, default_model: '@strong' };
  const session = { fixed_phase: 2 };
  const first = policy.route(config, session);
  assert.deepEqual(first.models.map(target => target.id), ['openrouter/glm-5.3', 'anthropic/claude-fable-5-1'],
    'a nested profile resolves through its chain');
  assert.equal(policy.route(config, { fixed_phase: 3 }).models[0].id, 'anthropic/claude-fable-5-1');
  // Re-point the profile; the same saved route now selects a different model.
  config.profiles.cheap = 'anthropic/claude-opus-5';
  assert.equal(policy.route(config, session).models[0].id, 'anthropic/claude-opus-5');
  // The context budget follows the resolution too.
  assert.doesNotThrow(() => policy.contextLimit(config));
});

test('profiles that do not resolve are rejected with a path to fix them', () => {
  const empty = { models: [{ id: 'anthropic/claude-fable-5-1', provider: 'anthropic', context_window: 200000 }], profiles: {}, phases: { 2: { model: '@ghost' } } };
  assert.throws(() => policy.route(empty, { fixed_phase: 2 }), /Profile ghost is not assigned a model\. Set one with dx profile set ghost/);
  const cycle = { models: [], profiles: { a: '@b', b: '@a' }, phases: { 2: { model: '@a' } } };
  assert.throws(() => policy.route(cycle, { fixed_phase: 2 }), /part of a cycle/);
  const self = { models: [], profiles: { a: '@a' }, phases: { 2: { model: '@a' } } };
  assert.throws(() => policy.route(self, { fixed_phase: 2 }), /part of a cycle/);
  // Two routes naming the same profile is fine; only a profile in its own chain is a cycle.
  const shared = { models: [{ id: 'anthropic/claude-fable-5-1', provider: 'anthropic', context_window: 200000 }],
    profiles: { strong: 'anthropic/claude-fable-5-1' }, phases: { 2: { model: '@strong', fallbacks: ['@strong'] } } };
  assert.equal(policy.route(shared, { fixed_phase: 2 }).models.length, 1);
});

test('profile names are rejected outside route configuration', () => {
  const config = { models: [{ id: 'anthropic/claude-fable-5-1', provider: 'anthropic', context_window: 200000 }] };
  assert.throws(() => policy.model(config, '@cheap'), /other commands need the provider\/model ID/);
});

test('review waves take turns over the models on their route', () => {
  const models = [
    { id: 'anthropic/claude-fable-5-1', provider: 'anthropic', context_window: 200000 },
    { id: 'anthropic/claude-opus-5', provider: 'anthropic', context_window: 200000 },
    { id: 'openai/gpt-6-astra', provider: 'openai', context_window: 200000 }
  ];
  const config = { models, phases: { 3: { model: models[0].id, fallbacks: models.slice(1).map(m => m.id) } }, profiles: {} };
  const wave = n => policy.route(config, { fixed_phase: 3, review_wave: n }).models.map(m => m.id);
  assert.deepEqual(wave(0), ['anthropic/claude-fable-5-1', 'anthropic/claude-opus-5', 'openai/gpt-6-astra']);
  assert.deepEqual(wave(1), ['anthropic/claude-opus-5', 'openai/gpt-6-astra', 'anthropic/claude-fable-5-1'],
    'the next wave leads with a different reviewer');
  assert.deepEqual(wave(2), ['openai/gpt-6-astra', 'anthropic/claude-fable-5-1', 'anthropic/claude-opus-5']);
  assert.deepEqual(wave(3), wave(0), 'the rotation wraps');
  // The order within a wave keeps the fallback chain: the leading model's
  // fallbacks follow it, so a provider failure still degrades in order.
  const one = policy.route(config, { fixed_phase: 3, review_wave: 0 });
  assert.deepEqual(one.models.map(m => m.id), config.phases[3] ? ['anthropic/claude-fable-5-1', 'anthropic/claude-opus-5', 'openai/gpt-6-astra'] : []);
  // A single-model route cannot be diverse, and must not break.
  const single = { models, phases: { 3: { model: models[0].id } }, profiles: {} };
  assert.deepEqual(policy.route(single, { fixed_phase: 3, review_wave: 4 }).models.map(m => m.id), ['anthropic/claude-fable-5-1']);
  // Sessions outside a review wave keep the configured order exactly.
  assert.deepEqual(policy.route(config, { fixed_phase: 3 }).models.map(m => m.id)[0], 'anthropic/claude-fable-5-1');
});

test('a metered account out of credit fails the route over instead of rejecting the request', () => {
  // 402 stops the account, not the request: every model on it is unusable until
  // it is topped up, so the request must reach whatever else can serve it.
  const out = policy.failure(402, {}, {}, 1000);
  assert.equal(out.retry, true, 'the request is retried on another candidate');
  assert.equal(out.reason, 'payment-required');
  assert.equal(out.modelOnly, undefined, 'the whole account is out, not one model');
  assert.ok(out.until > 1000);
  // 403 is about this model on this account, so another model may still serve.
  const refused = policy.failure(403, {}, {}, 1000);
  assert.equal(refused.retry, true);
  assert.equal(refused.reason, 'forbidden');
  assert.equal(refused.modelOnly, true);
  // A malformed request is still the request's own fault and is not failed over.
  assert.equal(policy.failure(400, {}, {}, 1000).retry, false);
  assert.equal(policy.failure(404, {}, {}, 1000).retry, false);
});

test('an exhausted metered route explains itself instead of looking like a login problem', () => {
  const glm = { id: 'openrouter/glm-5.3', provider: 'openrouter', display_name: 'GLM 5.3', context_window: 1048576 };
  const qwen = { id: 'openrouter/qwen3.8-max-0902', provider: 'openrouter', display_name: 'Qwen3.8 Max', context_window: 1000000 };
  const account = { id: 'a', name: 'openrouter', provider: 'openrouter', enabled: true, created_at: 1,
    cooldown_until: 1000 + 1800000, cooldown_reason: 'payment-required' };
  const selection = { phase: 2, models: [glm, qwen] };
  // Both models sit on the one exhausted account, so nothing can be selected.
  assert.equal(policy.candidates([account], selection, {}, 1000).length, 0);
  const error = policy.unavailable([account], selection, 1000, 'messages');
  assert.match(error.message, /provider credit exhausted/);
  assert.match(error.message, /A metered account is out of credit\. Top it up/);
  assert.equal(error.code, 'subscription_accounts_unavailable', 'Dex answers, not the raw provider status');
  assert.notEqual(error.status, 403, 'a client must not read this as an authentication failure');
  const refused = policy.unavailable([{ ...account, cooldown_until: undefined, cooldown_reason: undefined,
    model_cooldowns: { 'openrouter/glm-5.3@messages': 1000 + 300000, 'openrouter/qwen3.8-max-0902@messages': 1000 + 300000 },
    model_cooldown_reasons: { 'openrouter/glm-5.3@messages': 'forbidden', 'openrouter/qwen3.8-max-0902@messages': 'forbidden' } }],
    selection, 1000, 'messages');
  assert.match(refused.message, /not permitted by the provider/);
  assert.match(refused.message, /model permissions or guardrails/);
});

test('a deferred tool reference is normalised per provider, not refused', () => {
  const body = { messages: [{ role: 'assistant', content: [{ type: 'tool_reference', name: 'mcp__x__y' }] }] };
  // Tool search delivers the schema in the tools array, which every provider
  // reads, so no route needs to reject the block that accompanies it.
  for (const provider of ['anthropic', 'openai', 'openrouter']) {
    assert.doesNotThrow(() => policy.validateRequest(body, { id: `${provider}/m`, provider, capabilities: { tools: true } }, 'messages'),
      `${provider} must not refuse a tool_reference`);
  }
  // Content that genuinely cannot survive the conversion is still refused.
  for (const type of ['document', 'web_search_tool_result']) {
    assert.throws(() => policy.validateRequest({ messages: [{ role: 'user', content: [{ type }] }] },
      { id: 'openai/m', provider: 'openai', capabilities: { tools: true } }, 'messages'), /cannot preserve/);
  }
});
