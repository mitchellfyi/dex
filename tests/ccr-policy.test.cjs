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
});
test('unsupported content is rejected before routing', () => {
  assert.throws(() => policy.validateRequest({ messages: [{ role: 'user', content: [{ type: 'image' }] }] }, models[1]), /image/);
  assert.doesNotThrow(() => policy.validateRequest({ messages: [{ role: 'user', content: 'hello' }], tools: [{ name: 'Read' }] }, models[1]));
});
