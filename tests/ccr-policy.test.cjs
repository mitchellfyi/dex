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
test('a smaller context model can join a running session; each request is sized to the model serving it', () => {
  // The session was launched at a 200k budget; the phase route and an override both bring in a 128k model.
  assert.deepEqual(policy.route(config, { fixed_phase: 2, context_limit: 200000 }).models.map(x => x.id), ['openai/b', 'anthropic/a']);
  assert.deepEqual(policy.route(config, { fixed_phase: 0, context_limit: 200000, override: { model: 'openai/b', scope: 'session' } }).models.map(x => x.id), ['openai/b']);
  const small = { ...models[1], context_window: 8192, display_name: 'Small' };
  const oversized = { messages: [{ role: 'user', content: 'x'.repeat(8192 * 4) }] };
  assert.throws(() => policy.validateRequest(oversized, small), /8,192-token budget of Small.*Compact it \(\/compact\)/);
  assert.doesNotThrow(() => policy.validateRequest({ messages: [{ role: 'user', content: 'hello' }] }, small));
  assert.doesNotThrow(() => policy.validateRequest(oversized, models[0]), 'the same conversation fits the larger model');
  assert.throws(() => policy.validateRequest({ input: 'x'.repeat(8192 * 4) }, { ...small, display_name: undefined }, 'responses'), /budget of openai\/b/);
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
test('auth, quota, temporary failures and malformed requests are distinct', () => {
  assert.equal(policy.failure(401).reauth, true);
  assert.equal(policy.failure(429, {}, { 'retry-after': '120' }, 1000).until, 121000);
  assert.equal(policy.failure(503).retry, true);
  for (const code of [408, 409, 500, 502, 503, 504, 529]) assert.equal(policy.failure(code).modelOnly, true);
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
