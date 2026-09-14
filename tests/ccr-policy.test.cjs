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
test('phase override expires while session override remains', () => {
  const override = { model: 'anthropic/a', scope: 'phase', phase: 1 };
  assert.equal(policy.route(config, { fixed_phase: 2, override }).models[0].id, 'openai/b');
  override.scope = 'session';
  assert.equal(policy.route(config, { fixed_phase: 2, override }).models[0].id, 'anthropic/a');
});
test('context budget includes fallback models', () => assert.equal(policy.contextLimit(config), 128000));
test('smaller context model cannot be introduced into a running session', () => {
  assert.throws(() => policy.route(config, { fixed_phase: 2, context_limit: 200000 }), /smaller context/);
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
test('pinning never silently uses another account', () => {
  assert.deepEqual(policy.candidates([{ id: 'a', provider: 'anthropic', enabled: true }], { models, pinned: 'b' }, {}), []);
});
test('auth, quota, temporary failures and malformed requests are distinct', () => {
  assert.equal(policy.failure(401).reauth, true);
  assert.equal(policy.failure(429, {}, { 'retry-after': '120' }, 1000).until, 121000);
  assert.equal(policy.failure(503).retry, true);
  for (const code of [400, 403, 404, 422]) assert.equal(policy.failure(code).retry, false);
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
