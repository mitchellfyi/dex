'use strict';
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const state = require('../scripts/ccr/state.cjs');
const { RouterService } = require('../scripts/ccr/service.cjs');
let directory, server, service, endpoint, calls, reply, refreshes;
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
beforeEach(async () => {
  directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-service-')); process.env.DEX_ROUTER_HOME = directory;
  state.write(state.stateFile('config'), { version: 1, enabled: true, default_model: 'anthropic/test', phases: { 2: { model: 'openai/test', fallbacks: ['anthropic/test'] } }, models: ['anthropic/test', 'openai/test'].map(id => ({ id, provider: id.split('/')[0], context_window: 128000, capabilities: { tools: true } })) });
  state.saveAccounts(['one', 'two', 'three'].map((id, i) => ({ id, name: id, provider: i === 2 ? 'openai' : 'anthropic', enabled: true, status: 'ready', created_at: i })));
  calls = []; refreshes = [];
  reply = () => new Response(JSON.stringify({ content: [{ type: 'text', text: 'answer' }] }), { headers: { 'content-type': 'application/json' } });
  service = new RouterService({ gateway: 'http://127.0.0.1:1', clientKey: 'synthetic-local', broker: { access: async (account, force) => { refreshes.push({ id: account.id, force }); return { access_token: 'synthetic' }; }, usage: async () => ({ observed_at: Date.now(), windows: [] }) }, fetchImpl: async (_url, options) => { calls.push(JSON.parse(options.body)); return reply(options); } });
  await service.start(); server = http.createServer((req, res) => service.handle(req, res));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); endpoint = `http://127.0.0.1:${server.address().port}/v1/messages`;
});
afterEach(async () => { await service.stop(); await new Promise(resolve => server.close(resolve)); fs.rmSync(directory, { recursive: true, force: true }); });
async function register(id = 'session', extra = {}) { const token = state.token(); await service.control('register', { id, token, owner_pid: process.pid, ...extra }); return token; }
function send(token, extra = {}, headers = {}) { return fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, ...headers }, body: JSON.stringify({ model: 'dex/active', messages: [{ role: 'user', content: 'hello' }], ...extra }) }); }

test('routine health probes skip session scans while detailed status verifies owners', async t => {
  await register();
  state.write(state.sessionFile('stale'), { id: 'stale', active: true, owner_pid: process.pid, owner_identity: 'different-process-start' });
  assert.equal((await service.control('health', { sessions: true })).active_sessions, 1);
  t.mock.method(state, 'sessions', () => { throw new Error('Health must not scan session owners'); });
  const health = await service.control('health', {});
  assert.equal(health.pid, process.pid);
  assert.equal(health.owner_identity, service.ownerIdentity);
  assert.ok(health.owner_identity);
  assert.equal(health.active_requests, 0);
  assert.equal(health.active_sessions, undefined);
});
test('request diagnostics retain counts and correlation IDs without tool or prompt contents', async () => {
  const token = await register('metrics');
  reply = () => Response.json({ content: [{ type: 'text', text: 'PRIVATE ANSWER' }], usage: { input_tokens: 1, cache_read_input_tokens: 100000, cache_creation_input_tokens: 110000, output_tokens: 20 } }, { headers: { 'request-id': 'req_provider' } });
  const response = await send(token, { tools: [{ name: 'Read', description: 'PRIVATE SCHEMA', input_schema: {} }], system: 'PRIVATE SYSTEM' });
  await response.text();
  await wait(100);
  const saved = state.read(state.sessionFile('metrics')).last_request;
  assert.equal(saved.input_tokens, 210001);
  assert.equal(saved.tool_count, 1);
  assert.equal(saved.provider_request_id, 'req_provider');
  assert.match(response.headers.get('x-dex-request-id'), /^dxreq_/);
  const journal = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8');
  assert.match(journal, /router.request_completed/);
  assert.doesNotMatch(journal + JSON.stringify(saved), /PRIVATE|synthetic-local|Bearer/);
});

test('native credentials are stable per client process and use the configured fallback chain', async () => {
  const config = state.config(); config.native = { enabled: true }; config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/test'] }; state.write(state.stateFile('config'), config);
  const params = { client: 'codex', owner_pid: process.pid };
  const first = await service.control('native-auth', params);
  assert.deepEqual(await service.control('native-auth', params), first);
  assert.notDeepEqual(await service.control('native-auth', { ...params, client: 'claude' }), first);
  endpoint = endpoint.replace('/messages', '/responses');
  reply = () => new Response('{}', { status: calls.length < 3 ? 429 : 200 });
  const input = [{ role: 'user', content: [{ type: 'input_text', text: 'hello' }] }, { type: 'function_call', call_id: 'call_1', name: 'run', arguments: '{}' }, { type: 'function_call_output', call_id: 'call_1', output: 'done' }];
  assert.equal((await send(first.token, { input })).status, 200);
  assert.deepEqual(calls.map(call => call.model), ['dex-anthropic/test', 'dex-anthropic/test', 'dex-openai/test']);
  assert.deepEqual(calls[2].input, input);
  const session = state.read(state.sessionFile(`native-codex-${process.pid}`));
  assert.equal(session.current_model, 'openai/test'); assert.equal(session.override, undefined);
  assert.equal(session.auth_hash, state.hash(first.token)); assert.equal(JSON.stringify(session).includes(first.token), false);
  // The converted Codex requests cooled the Claude accounts for Responses only.
  const anthropic = state.accounts().filter(account => account.provider === 'anthropic');
  assert.ok(anthropic.every(account => account.model_cooldowns['anthropic/test@responses'] > Date.now() && account.model_cooldowns['anthropic/test'] === undefined));
  const events = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse).filter(event => event.type === 'account.failover');
  assert.deepEqual(events.map(event => [event.data.protocol, event.data.provider_error]), [['responses', null], ['responses', null]]);
  endpoint = endpoint.replace('/responses', '/messages');
  const claude = await service.control('native-auth', { ...params, client: 'claude' });
  assert.equal((await send(claude.token)).status, 200);
  assert.equal(calls.at(-1).model, 'dex-anthropic/test', 'native Claude traffic is not blocked by the Codex conversion failures');
  config.native.enabled = false; state.write(state.stateFile('config'), config);
  assert.deepEqual(await service.control('native-auth', params), first, 'running clients can finish after disabling native defaults');
});

test('a model a native client names explicitly never moves the work to another provider', async () => {
  const config = state.config(); config.native = { enabled: true };
  config.models.find(model => model.id === 'openai/test').upstream_id = 'codex-test';
  // The automatic route can cross providers; naming a model must not.
  config.phases[0] = { model: 'openai/test', fallbacks: ['anthropic/test'] };
  config.client_routes = { codex: { model: 'openai/test', fallbacks: ['anthropic/test'] } };
  state.write(state.stateFile('config'), config);
  const { token } = await service.control('native-auth', { client: 'codex', owner_pid: process.pid });
  endpoint = endpoint.replace('/messages', '/responses');
  reply = options => JSON.parse(options.body).model === 'dex-openai/codex-test'
    ? new Response('{}', { status: 429, headers: { 'retry-after': '60' } })
    : new Response('{}');
  const input = [{ role: 'user', content: [{ type: 'input_text', text: 'hello' }] }];
  const response = await send(token, { model: 'codex-test', input });
  // Choosing a model chooses its provider too, so the rate limit stops here
  // rather than quietly spending on a different bill.
  assert.equal(response.status, 429);
  assert.deepEqual(calls.map(call => call.model), ['dex-openai/codex-test']);
});

test('Codex reads a catalogue that mirrors the routed OpenAI model under the dex/active alias', async () => {
  const config = state.config(); config.native = { enabled: true }; config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/test'] }; state.write(state.stateFile('config'), config);
  const { token } = await service.control('native-auth', { client: 'codex', owner_pid: process.pid });
  const urls = [];
  const upstream = { slug: 'test', display_name: 'Test', description: 'upstream', default_reasoning_level: 'high', supported_reasoning_levels: [{ effort: 'high', description: 'h' }], shell_type: 'unified_exec', visibility: 'list', supported_in_api: true, priority: 3, upgrade: null, support_verbosity: true, default_verbosity: 'low', apply_patch_tool_type: 'freeform', truncation_policy: { mode: 'tokens', limit: 10000 }, supports_image_detail_original: true, context_window: 272000, max_context_window: 272000, experimental_supported_tools: [], model_messages: { instructions_template: 'upstream instructions' } };
  service.fetch = async url => { urls.push(url); return new Response(JSON.stringify({ models: [upstream, { slug: 'other', display_name: 'Other' }] })); };
  upstream.auto_compact_token_limit = 240000;
  const catalogue = async (query = '?client_version=0.154.0', bearer = token) => fetch(endpoint.replace('/v1/messages', `/v1/models${query}`), { headers: { authorization: `Bearer ${bearer}` } });
  let response = await catalogue(); assert.equal(response.status, 200);
  let body = await response.json();
  assert.equal(body.models[0].slug, 'dex/active');
  assert.equal(body.models[0].display_name, 'Dex automatic route');
  assert.equal(body.models[0].apply_patch_tool_type, 'freeform');
  assert.equal(body.models[0].default_reasoning_level, 'high', 'metadata comes from the routed OpenAI model');
  assert.equal(body.models[0].model_messages.instructions_template, 'upstream instructions');
  assert.equal(body.models[0].context_window, 128000); assert.equal(body.models[0].max_context_window, 128000);
  assert.equal(body.models[0].auto_compact_token_limit, 102400);
  assert.deepEqual(body.models.slice(1).map(item => item.slug), ['test', 'other']);
  assert.equal(refreshes.at(-1).id, 'three', 'the OpenAI account fetched the catalogue');
  assert.match(urls[0], /chatgpt\.com\/backend-api\/codex\/models\?client_version=0\.154\.0$/);
  await catalogue(); assert.equal(urls.length, 1, 'the upstream catalogue is cached');
  config.models[1].context_window = 64000; state.write(state.stateFile('config'), config);
  body = await (await catalogue()).json();
  assert.equal(body.models[0].context_window, 64000);
  assert.equal(body.models[0].max_context_window, 64000);
  assert.equal(body.models[0].auto_compact_token_limit, 51200);
  // Without an OpenAI model on the route Codex still gets full native tooling.
  config.phases[0] = { model: 'anthropic/test', fallbacks: [] }; state.write(state.stateFile('config'), config);
  body = await (await catalogue()).json();
  assert.equal(body.models.length, 1); assert.equal(body.models[0].slug, 'dex/active');
  assert.equal(body.models[0].apply_patch_tool_type, 'freeform'); assert.equal(body.models[0].include_skills_usage_instructions, true);
  assert.ok(body.models[0].supported_reasoning_levels.some(level => level.effort === 'xhigh'));
  assert.equal(urls.length, 1);
  // Claude keeps the Messages catalogue shape.
  const claude = await register();
  body = await (await catalogue('', claude)).json();
  assert.deepEqual(body.data.map(item => item.id), ['anthropic/test', 'openai/test']);
  assert.equal((await catalogue('?client_version=0.154.0', 'not-a-session')).status, 401);
});
test('quota exhaustion does not hide Codex metadata or reduce the configured long-context budget', async () => {
  const config = state.config(); config.context_budget = 800000;
  config.models = config.models.map(model => ({ ...model, context_window: model.provider === 'openai' ? 272000 : 1000000, max_context_window: model.provider === 'openai' ? 872000 : 1000000 }));
  config.phases[0] = { model: 'openai/test', fallbacks: ['anthropic/test'] }; state.write(state.stateFile('config'), config);
  state.saveAccounts(state.accounts().map(account => account.provider === 'openai' ? { ...account, usage: { observed_at: Date.now(), windows: [{ remaining_ratio: 0, name: 'weekly', resets_at: Date.now() + 86400000 }] } } : account));
  const token = await register('long-context');
  service.fetch = async () => Response.json({ models: [{ slug: 'test', context_window: 272000, max_context_window: 872000, model_messages: { instructions_template: 'Native Codex instructions' } }] });
  const result = await fetch(endpoint.replace('/v1/messages', '/v1/models?client_version=0.155.0'), { headers: { authorization: `Bearer ${token}` } });
  const body = await result.json();
  assert.equal(body.models[0].context_window, 800000);
  assert.equal(body.models[0].auto_compact_token_limit, 640000);
  assert.equal(body.models[0].model_messages.instructions_template, 'Native Codex instructions');
  assert.equal(body.models[1].max_context_window, 872000);
});

test('an exhausted launch route can move to a smaller context model without a restart', async () => {
  const config = state.config(); config.native = { enabled: true };
  config.models.push({ id: 'openai/small', upstream_id: 'small', provider: 'openai', context_window: 8192, capabilities: { tools: true } });
  state.write(state.stateFile('config'), config);
  // Native Codex launched at the 128k Claude-only route budget; both Claude accounts are then exhausted.
  const { token } = await service.control('native-auth', { client: 'codex', owner_pid: process.pid });
  const id = `native-codex-${process.pid}`;
  assert.equal(state.read(state.sessionFile(id)).context_limit, 128000);
  state.saveAccounts(state.accounts().map(account => account.provider === 'anthropic' ? { ...account, cooldown_until: Date.now() + 3600000, cooldown_reason: 'rate-limit' } : account));
  endpoint = endpoint.replace('/messages', '/responses');
  const input = [{ role: 'user', content: [{ type: 'input_text', text: 'hello' }] }];
  let response = await send(token, { input });
  assert.equal(response.status, 429);
  assert.match((await response.json()).error.message, /needs CCR responses conversion.*dx route use openai\/<model>/);
  // 1. Codex /model picks the smaller OpenAI model by its upstream name.
  response = await send(token, { model: 'small', input });
  assert.equal(response.status, 200, await response.text());
  assert.equal(response.headers.get('x-dex-model'), 'openai/small');
  assert.deepEqual(calls.map(call => call.model), ['dex-openai/small']);
  assert.equal(state.read(state.sessionFile(id)).context_limit, 128000, 'the launch budget is a record, not a floor');
  // 2. dx route use selects it for the rest of the session.
  const routed = await service.control('route', { action: 'use', model: 'openai/small', session: id });
  assert.deepEqual(routed.route.models.map(model => model.id), ['openai/small']);
  assert.equal((await send(token, { input })).status, 200);
  assert.equal(calls.at(-1).model, 'dex-openai/small');
  // 3. dx route configure adds it as a fallback while the session is running.
  config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/small'] }; state.write(state.stateFile('config'), config);
  assert.deepEqual((await service.control('route', { action: 'auto', session: id })).route.models.map(model => model.id), ['anthropic/test', 'openai/small']);
  response = await send(token, { input });
  assert.equal(response.status, 200); assert.equal(response.headers.get('x-dex-model'), 'openai/small');
  assert.equal(calls.length, 3, 'exhausted Claude accounts are skipped without a provider call');
  // Repeated text can occupy many bytes while using relatively few tokens.
  const oversized = [{ role: 'user', content: [{ type: 'input_text', text: 'x'.repeat(8192 * 4) }] }];
  response = await send(token, { model: 'small', input: oversized });
  assert.equal(response.status, 200, await response.text());
  assert.equal(calls.length, 4, 'the provider determines whether the input fits');
  assert.deepEqual(calls.at(-1).input, oversized);
  assert.equal(state.read(state.sessionFile(id)).active, true);
});

test('provider context errors remain recognizable and a compacted request can continue', async () => {
  endpoint = endpoint.replace('/messages', '/responses');
  const token = await register('context-recovery', { model: 'openai/test' });
  reply = () => Response.json({ error: { code: 'context_length_exceeded', type: 'invalid_request_error', message: 'private prompt details' } }, { status: 400 });
  const rejected = await send(token, { input: 'conversation' });
  assert.equal(rejected.status, 400);
  assert.deepEqual((await rejected.json()).error, {
    type: 'invalid_request_error', code: 'context_length_exceeded',
    message: 'The conversation exceeds the selected model\'s context window. Compact it with /compact or select a model with a larger context window.',
    provider_status: 400
  });
  assert.equal(calls.length, 1);
  assert.ok(state.accounts().every(account => !account.cooldown_until && !account.model_cooldowns));
  reply = () => Response.json({ output: [] });
  assert.equal((await send(token, { input: 'compacted summary' })).status, 200);
  assert.equal(calls.length, 2);
  assert.equal(state.read(state.sessionFile('context-recovery')).active, true);
});

for (const details of [
  { error: { type: 'invalid_request_error', message: 'prompt is too long: private prompt details' } },
  { detail: 'Your input exceeds the context window of this model. private prompt details' },
  { response: { error: { code: 'context_length_exceeded', message: 'private prompt details' } } }
]) test('Claude recognizes context errors from upstream envelopes without leaking their messages', async () => {
  const token = await register('claude-context');
  reply = () => Response.json({ error: { attempts: [{ status: 400, stage: 'upstream_response', details }] } }, { status: 400 });
  const result = await send(token);
  const body = await result.json();
  assert.equal(result.status, 400);
  assert.equal(body.error.code, 'context_length_exceeded');
  assert.match(body.error.message, /^prompt is too long:/);
  assert.doesNotMatch(JSON.stringify(body), /private prompt/);
  assert.ok(state.accounts().every(account => !account.cooldown_until && !account.model_cooldowns));
});

test('a completed lifecycle keeps serving requests on its complete route', async () => {
  const config = state.config(); config.phases[6] = { model: 'openai/test', fallbacks: [] }; state.write(state.stateFile('config'), config);
  const phase = path.join(directory, 'lifecycle.phase'); fs.writeFileSync(phase, '6\n', { mode: 0o600 });
  const token = await register('session', { phase_file: phase });
  assert.equal((await send(token)).status, 200); fs.writeFileSync(phase, '7\n');
  const response = await send(token);
  assert.equal(response.status, 200, await response.text());
  assert.deepEqual(calls.map(call => call.model), ['dex-openai/test', 'dex-openai/test']);
  assert.equal(state.read(state.sessionFile('session')).phase, 7);
  assert.equal((await service.control('route', { action: 'status', session: 'session' })).route.phase, 7);
});

test('failover events keep a cleaned provider explanation', async () => {
  const token = await register();
  reply = () => new Response(JSON.stringify({ error: { type: 'rate_limit_error', message: `Retry\u001b[2J later ${'x'.repeat(300)}` } }), { status: 429, headers: { 'retry-after': '60' } });
  assert.equal((await send(token)).status, 429);
  const events = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse).filter(event => event.type === 'account.failover');
  assert.equal(events.length, 2);
  assert.equal(events[0].data.protocol, 'messages');
  assert.equal(events[0].data.provider_error.type, 'rate_limit_error');
  assert.equal(events[0].data.provider_error.message.length, 200);
  assert.equal(events[0].data.provider_error.message.includes(''), false);
});

test('Responses forwarding preserves protocol, validates images and rejects missing conversation input', async () => {
  const token = await register(); endpoint = endpoint.replace('/messages', '/responses');
  const urls = []; const originalFetch = service.fetch;
  service.fetch = (url, options) => { urls.push(url); return originalFetch(url, options); };
  assert.equal((await send(token, { input: 'hello' })).status, 200);
  assert.match(urls[0], /\/v1\/responses$/);
  assert.equal((await send(token, { input: [{ role: 'user', content: [{ type: 'input_image', image_url: 'data:image/png;base64,AAAA' }] }] })).status, 503);
  assert.equal((await send(token, { input: 'hello', previous_response_id: 'response_from_another_account' })).status, 503);
  assert.equal(calls.length, 1);
});

test('phase change is read between requests without changing session ownership', async () => {
  const phase = path.join(directory, 'lifecycle.phase'); fs.writeFileSync(phase, '1', { mode: 0o600 });
  const token = await register('session', { phase_file: phase });
  assert.equal((await send(token)).status, 200); fs.writeFileSync(phase, '2');
  assert.equal((await send(token)).status, 200);
  assert.deepEqual(calls.map(call => call.model), ['dex-anthropic/test', 'dex-openai/test']);
  assert.equal(state.read(state.sessionFile('session')).owner_pid, process.pid);
});
test('fallback survives recovered quotas and resume, and resets on phase or route changes', async () => {
  const config = state.config();
  config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/test'], effort: 'xhigh' };
  config.phases[1] = { ...config.phases[0] };
  state.write(state.stateFile('config'), config);
  const phase = path.join(directory, 'phase'); fs.writeFileSync(phase, '0', { mode: 0o600 });
  let token = await register('sticky', { phase_file: phase });
  reply = () => new Response('{}', { status: calls.at(-1).model.startsWith('dex-anthropic') ? 429 : 200 });
  assert.equal((await send(token)).status, 200);
  assert.deepEqual(calls.map(call => call.model), ['dex-anthropic/test', 'dex-anthropic/test', 'dex-openai/test']);
  state.saveAccounts(state.accounts().map(account => ({ ...account, model_cooldowns: {} })));
  reply = () => Response.json({});
  assert.equal((await send(token)).status, 200);
  assert.equal(calls.at(-1).model, 'dex-openai/test');
  await service.control('finish', { id: 'sticky', token });
  token = await register('sticky', { phase_file: phase });
  assert.equal((await send(token)).status, 200);
  assert.equal(calls.at(-1).model, 'dex-openai/test');
  fs.writeFileSync(phase, '1');
  assert.equal((await send(token)).status, 200);
  assert.equal(calls.at(-1).model, 'dex-anthropic/test');
  await service.control('route', { action: 'use', session: 'sticky', model: 'openai/test' });
  assert.equal((await send(token)).status, 200);
  assert.equal(calls.at(-1).output_config.effort, 'xhigh');
  await service.control('route', { action: 'auto', session: 'sticky' });
  assert.equal((await send(token)).status, 200);
  assert.equal(calls.at(-1).model, 'dex-anthropic/test');
});
test('a working fallback still fails back automatically if it becomes unavailable', async () => {
  const config = state.config(); config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/test'] }; state.write(state.stateFile('config'), config);
  const token = await register();
  reply = () => new Response('{}', { status: calls.at(-1).model.startsWith('dex-anthropic') ? 429 : 200 });
  assert.equal((await send(token)).status, 200);
  state.saveAccounts(state.accounts().map(account => ({ ...account, model_cooldowns: {} })));
  reply = () => new Response('{}', { status: calls.at(-1).model.startsWith('dex-openai') ? 429 : 200 });
  const before = calls.length;
  assert.equal((await send(token)).status, 200);
  assert.deepEqual(calls.slice(before).map(call => call.model), ['dex-openai/test', 'dex-anthropic/test']);
});
test('resetting automatic routing during a request is not undone by its response', async () => {
  const config = state.config(); config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/test'] }; state.write(state.stateFile('config'), config);
  const token = await register();
  let release, started;
  const ready = new Promise(resolve => { started = resolve; });
  reply = () => new Promise(resolve => { release = resolve; started(); });
  const pending = send(token);
  await ready;
  await service.control('route', { action: 'auto', session: 'session' });
  release(Response.json({}));
  assert.equal((await pending).status, 200);
  assert.equal(state.read(state.sessionFile('session')).current_route, undefined);
});
test('a rejection identifies the failing model even after another provider succeeded', async () => {
  const token = await register('rejected-status', { model: 'openai/test' });
  assert.equal((await send(token)).status, 200);
  await service.control('route', { action: 'auto', session: 'rejected-status' });
  reply = () => Response.json({ error: { type: 'invalid_request_error' } }, { status: 400 });
  assert.equal((await send(token)).status, 400);
  const saved = state.read(state.sessionFile('rejected-status'));
  assert.equal(saved.current_model, 'openai/test');
  assert.deepEqual(saved.last_rejection, { model: 'anthropic/test', status: 400 });
  reply = () => Response.json({});
  assert.equal((await send(token)).status, 200);
  assert.equal(state.read(state.sessionFile('rejected-status')).last_rejection, undefined);
});
test('two simultaneous sessions keep independent overrides and capabilities', async () => {
  const one = await register('one'); const two = await register('two');
  await service.control('route', { session: 'one', action: 'use', model: 'openai/test' });
  const responses = await Promise.all([send(one), send(two)]); assert.ok(responses.every(response => response.status === 200));
  assert.equal(state.read(state.sessionFile('one')).current_model, 'openai/test'); assert.equal(state.read(state.sessionFile('two')).current_model, 'anthropic/test');
  await assert.rejects(service.control('route', { action: 'use', model: 'openai/test' }), /Several sessions/);
  assert.equal((await send('not-a-session')).status, 401);
});
test('rejected request does not rotate accounts or mark their quota exhausted', async () => {
  const token = await register(); reply = () => new Response('{"error":{"type":"invalid_request_error"}}', { status: 400 });
  assert.equal((await send(token)).status, 400); assert.equal(calls.length, 1); assert.ok(state.accounts().every(account => !account.cooldown_until));
});
const termsMessage = "We've updated our Consumer Terms and Privacy Policy. You'll need to accept them in claude.ai with the email in /status to continue.";
for (const wrapped of [false, true]) test(`terms acceptance rotates accounts and recovers without reauth (${wrapped ? 'CCR wrapper' : 'direct'})`, async t => {
  const token = await register();
  const details = { error: { type: 'invalid_request_error', message: `${termsMessage} private provider detail` } };
  reply = () => calls.length === 1 ? Response.json(wrapped ? { error: { attempts: [{ status: 400, details }] } } : details, { status: 400 }) : Response.json({});
  assert.equal((await send(token)).status, 200);
  assert.deepEqual(refreshes.map(item => item.id), ['one', 'two']);
  const blocked = state.accounts()[0];
  assert.equal(blocked.cooldown_reason, 'terms-required');
  assert.equal(blocked.status, 'ready');
  assert.equal(blocked.model_cooldowns, undefined);
  assert.equal(state.read(state.sessionFile('session')).current_account, 'two');
  const journal = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8');
  assert.match(journal, /terms-required/);
  assert.doesNotMatch(journal, /private provider detail/);
  await service.control('route', { action: 'pin', account: 'one', session: 'session' });
  const response = await send(token);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error.message, /one: accept updated terms in claude\.ai/);
  assert.equal(calls.length, 2, 'pinning cannot bypass terms or select another account');
  t.mock.method(Date, 'now', () => blocked.cooldown_until + 1);
  assert.equal((await send(token)).status, 200);
  assert.equal(refreshes.at(-1).id, 'one');
  assert.equal(state.read(state.sessionFile('session')).current_account, 'one');
});
test('terms errors skip other models on the same account and explain how to restore access', async () => {
  const config = state.config();
  config.models.push({ ...config.models[0], id: 'anthropic/fallback' });
  config.phases[0] = { model: 'anthropic/test', fallbacks: ['anthropic/fallback'] };
  state.write(state.stateFile('config'), config);
  const token = await register();
  reply = () => Response.json({ error: { type: 'invalid_request_error', message: termsMessage } }, { status: 403 });
  const response = await send(token);
  assert.equal(response.status, 400);
  const message = (await response.json()).error.message;
  assert.match(message, /one: accept updated terms in claude\.ai/);
  assert.match(message, /two: accept updated terms in claude\.ai/);
  assert.match(message, /Sign in to claude\.ai.*Consumer Terms and Privacy Policy/);
  assert.match(message, /dx account show <name>/);
  assert.equal(calls.length, 2, 'each account is tried once across the model chain');
  assert.ok(refreshes.every(item => !item.force));
});
test('terms detection is limited to the known Anthropic account error', async () => {
  const token = await register('openai-terms', { model: 'openai/test' });
  reply = () => Response.json({ error: { type: 'invalid_request_error', message: termsMessage } }, { status: 400 });
  const response = await send(token);
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, 'provider_request_rejected');
  assert.ok(state.accounts().every(account => !account.cooldown_until));
  assert.equal(calls.length, 1);
});
for (const wrapped of [false, true]) test(`request rejection exposes safe provider fields (${wrapped ? 'CCR wrapper' : 'direct'})`, async () => {
  const token = await register('rejected', { model: 'openai/test' });
  const error = { type: 'invalid_request_error', code: 'array_above_max_length', param: 'input[1].content', message: 'private prompt details and credentials' };
  reply = () => Response.json(wrapped ? { error: { message: 'Gateway failure', attempts: [{ status: 400, stage: 'upstream_response', details: { error } }] } } : { error }, { status: 400 });
  const response = await send(token);
  const body = await response.json();
  assert.equal(response.status, 400);
  assert.match(body.error.message, /openai\/test.*array_above_max_length at input\[1\].content/);
  assert.equal(body.error.code, 'provider_request_rejected');
  assert.deepEqual(body.error.provider_error, { type: error.type, code: error.code, param: error.param });
  const journal = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8');
  assert.doesNotMatch(JSON.stringify(body) + journal, /private prompt|credentials/);
  const event = journal.trim().split('\n').map(JSON.parse).find(event => event.type === 'router.request_rejected');
  assert.equal(event.data.model, 'openai/test');
  assert.deepEqual(event.data.provider_error, body.error.provider_error);
  assert.equal(calls.length, 1);
  assert.ok(state.accounts().every(account => !account.cooldown_until && !account.model_cooldowns));
});
test('rejection diagnostics exclude malformed error fields and terminal controls', async () => {
  const token = await register();
  reply = () => Response.json({ error: { type: 'private\ntext', code: 'secret=value', param: 'input["private text"]' } }, { status: 400 });
  const body = await (await send(token)).json();
  assert.deepEqual(body.error.provider_error, { type: null, code: null, param: null });
  assert.doesNotMatch(JSON.stringify(body), /private|secret/);
});
for (const protocol of ['messages', 'responses']) for (const model of ['anthropic/test', 'openai/test']) test(`${protocol} carries configured effort through routing to ${model}`, async () => {
  endpoint = endpoint.replace('/messages', `/${protocol}`);
  const config = state.config(); config.phases[0] = { model, effort: 'xhigh' }; state.write(state.stateFile('config'), config);
  const token = await register();
  assert.equal((await send(token, { input: 'hello', output_config: { effort: 'high' }, reasoning: { effort: 'high', summary: 'auto' } })).status, 200);
  assert.equal(calls[0][protocol === 'messages' ? 'output_config' : 'reasoning'].effort, 'xhigh');
  if (protocol === 'responses') assert.equal(calls[0].reasoning.summary, 'auto');
});
test('401 refreshes once before moving to another account', async () => {
  const token = await register(); reply = () => new Response('{}', { status: calls.length <= 2 ? 401 : 200 });
  assert.equal((await send(token)).status, 200);
  assert.deepEqual(refreshes.map(item => [item.id, Boolean(item.force)]), [['one', false], ['one', true], ['two', false]]);
  assert.equal(state.accounts()[0].status, 'reauth-required');
});
test('all exhausted accounts preserve route state without claiming a successful response', async () => {
  const token = await register(); reply = () => new Response('{}', { status: 429, headers: { 'retry-after': '60' } });
  const response = await send(token);
  assert.equal(response.status, 429); assert.equal(calls.length, 2);
  assert.ok(Number(response.headers.get('retry-after')) > 0);
  const error = (await response.json()).error;
  assert.equal(error.retry_after_seconds, Number(response.headers.get('retry-after')));
  assert.equal(error.code, 'subscription_accounts_unavailable');
  assert.equal(error.type, 'rate_limit_error');
  assert.match(error.message, /one: rate limited/);
  assert.match(error.message, /two: rate limited/);
  assert.doesNotMatch(error.message, /reauth/);
  assert.equal((await send(token)).status, 429); assert.equal(calls.length, 2, 'retries during cooldown do not call the provider');
  const session = state.read(state.sessionFile('session')); assert.equal(session.active, true); assert.equal(session.paused_reason, 'no-completed-response');
});
for (const protocol of ['messages', 'responses']) test(`${protocol} reports weekly quota exhaustion without a server-error status`, async () => {
  const config = state.config(); config.models.push({ ...config.models[0], id: 'anthropic/fallback' });
  config.phases[0] = { model: 'anthropic/test', fallbacks: ['anthropic/fallback'] }; state.write(state.stateFile('config'), config);
  const token = await register(); endpoint = endpoint.replace('/messages', `/${protocol}`);
  state.saveAccounts(state.accounts().map(account => account.provider === 'anthropic' ? { ...account, usage: { observed_at: Date.now(), windows: [
    { name: 'weekly', remaining_ratio: 0, resets_at: Date.now() + 141921000 }
  ] }, model_cooldowns: { 'anthropic/test': Date.now() + 30000 } } : account));
  const response = await send(token, protocol === 'responses' ? { input: 'hello' } : {});
  assert.equal(response.status, 429);
  assert.equal(calls.length, 0, 'known exhaustion does not call the provider');
  const error = (await response.json()).error;
  assert.equal(error.type, 'rate_limit_error');
  assert.equal(error.code, 'subscription_accounts_unavailable');
  assert.equal(error.retry_after_seconds, Number(response.headers.get('retry-after')));
  assert.ok(error.retry_after_seconds > 141900 && error.retry_after_seconds <= 141921);
  assert.match(error.message, /^Subscription quota exhausted on this route\./);
  assert.match(error.message, /Retry in 2d\./);
  assert.match(error.message, /No OpenAI fallback is configured/);
});
test('native Claude displays quota exhaustion without temporary-server-error advice', { skip: process.env.DEX_CCR_NATIVE_CLAUDE !== '1', timeout: 45000 }, async () => {
  const token = await register();
  state.saveAccounts(state.accounts().map(account => account.provider === 'anthropic' ? { ...account, usage: { observed_at: Date.now(), windows: [
    { name: 'weekly', remaining_ratio: 0, resets_at: Date.now() + 141921000 }
  ] } } : account));
  const nativeHome = state.privateDir(path.join(directory, 'native-claude'));
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, CLAUDE_CONFIG_DIR: nativeHome,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', CLAUDE_CODE_MAX_RETRIES: '0', DEX_SESSION_ONLY: '1',
    ANTHROPIC_BASE_URL: new URL(endpoint).origin, ANTHROPIC_AUTH_TOKEN: token, TERM: 'dumb' };
  const child = spawn('claude', ['-p', 'hello', '--model', 'dex/active', '--output-format', 'json', '--no-session-persistence',
    '--setting-sources', 'user', '--settings', '{"disableAllHooks":true}', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
    '--dangerously-skip-permissions', '--permission-mode', 'bypassPermissions'], { cwd: nativeHome, env, stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000 });
  let output = '', errors = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { errors += chunk; });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  assert.equal(code, 1, `${output}\n${errors}`);
  const result = JSON.parse(output);
  assert.equal(result.is_error, true);
  assert.equal(result.api_error_status, 429);
  assert.match(result.result, /Subscription quota exhausted on this route/);
  assert.match(result.result, /Retry in 2d/);
  assert.match(result.result, /No OpenAI fallback is configured/);
  assert.doesNotMatch(result.result, /server-side issue|try again in a moment|usually temporary/);
  assert.equal(calls.length, 0);
});
for (const protocol of ['messages', 'responses']) for (const errorStatus of [429, 503, 529]) test(`${protocol} uses another model after both primary accounts return ${errorStatus}`, async () => {
  const config = state.config(); config.models.push({ ...config.models[0], id: 'anthropic/fallback' });
  config.phases[0] = { model: 'anthropic/test', fallbacks: ['anthropic/fallback'] }; state.write(state.stateFile('config'), config);
  const token = await register(); endpoint = endpoint.replace('/messages', `/${protocol}`);
  reply = options => JSON.parse(options.body).model === 'dex-anthropic/test'
    ? new Response('{}', { status: errorStatus, headers: { 'retry-after': '60' } })
    : new Response(JSON.stringify({ content: [{ type: 'text', text: 'fallback answer' }] }));
  const extra = protocol === 'responses' ? { input: 'hello' } : {};
  assert.equal((await send(token, extra)).status, 200);
  assert.deepEqual(calls.map(call => call.model), ['dex-anthropic/test', 'dex-anthropic/test', 'dex-anthropic/fallback']);
  const accounts = state.accounts().filter(account => account.provider === 'anthropic');
  // Codex traffic reaches Claude models through CCR conversion and cools down on its own key.
  const key = protocol === 'responses' ? 'anthropic/test@responses' : 'anthropic/test';
  assert.ok(accounts.every(account => account.model_cooldowns[key] > Date.now() && !account.cooldown_until && Object.keys(account.model_cooldowns).length === 1));
  assert.ok(accounts.every(account => account.model_cooldown_reasons[key] === (errorStatus === 429 ? 'rate-limit' : 'temporary')));
  const next = await send(token, extra);
  assert.equal(next.status, 200);
  assert.equal(next.headers.get('x-dex-model'), 'anthropic/fallback');
  assert.deepEqual(calls.map(call => call.model).slice(3), ['dex-anthropic/fallback']);
  assert.equal(state.read(state.sessionFile('session')).current_model, 'anthropic/fallback');
  state.saveAccounts(state.accounts().map(account => ({ ...account, model_cooldowns: {} })));
  reply = () => new Response('{}');
  assert.equal((await send(token, extra)).headers.get('x-dex-model'), 'anthropic/fallback', 'a working fallback survives the primary cooldown');
  await service.control('route', { action: 'auto', session: 'session' });
  assert.equal((await send(token, extra)).headers.get('x-dex-model'), 'anthropic/test', 'auto retries the configured primary');
  const events = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  const failures = events.filter(event => event.type === 'account.failover');
  assert.ok(failures.every(event => event.data.scope === 'model' && event.data.provider_status === errorStatus && event.data.retry_at > Date.now()));
  assert.equal(failures.length, 2);
});
test('fallbacks recheck account-wide failures before trying another model', async () => {
  const config = state.config(); config.models.push({ ...config.models[0], id: 'anthropic/fallback' });
  config.phases[0] = { model: 'anthropic/test', fallbacks: ['anthropic/fallback'] }; state.write(state.stateFile('config'), config);
  const token = await register(); reply = () => { throw new Error('Synthetic connection failure'); };
  const response = await send(token);
  assert.equal(response.status, 503); assert.equal(calls.length, 2);
  assert.ok(Number(response.headers.get('retry-after')) <= 10);
  assert.match((await response.json()).error.message, /connection failed/);
});
test('login failures name the affected accounts without inventing a retry time', async () => {
  const token = await register();
  service.broker.access = async () => { throw Object.assign(new Error('synthetic login failure'), { reauth: true }); };
  const response = await send(token);
  // Every account needs a new login, so asking again cannot help. A 5xx would
  // put the client into a retry loop that hides the instruction below.
  assert.equal(response.status, 400); assert.equal(calls.length, 0);
  assert.equal(response.headers.get('retry-after'), null);
  const error = (await response.json()).error;
  assert.equal(error.type, 'invalid_request_error');
  assert.match(error.message, /one: login needs renewal/);
  assert.match(error.message, /two: login needs renewal/);
  assert.match(error.message, /dx account reauth <name>/);
  assert.equal(error.retry_after_seconds, undefined);
});
test('connection failures and unavailable login refreshes get distinct cooldown errors', async () => {
  const token = await register();
  service.fetch = async () => { throw new Error('synthetic private connection detail'); };
  let response = await send(token);
  assert.match((await response.json()).error.message, /connection failed/);
  assert.ok(Number(response.headers.get('retry-after')) > 0);
  state.saveAccounts(state.accounts().map(account => ({ ...account, cooldown_until: 0 })));
  service.broker.access = async () => { throw new Error('synthetic private credential detail'); };
  response = await send(token);
  const error = (await response.json()).error;
  assert.match(error.message, /login refresh temporarily unavailable/);
  assert.doesNotMatch(error.message, /reauth|synthetic private/);
  assert.ok(Number(response.headers.get('retry-after')) > 0);
});
test('a temporary refresh failure cools the account without requiring another login', async () => {
  const token = await register(); const original = service.broker.access;
  service.broker.access = async (account, force) => { if (force) throw new Error('Provider temporarily unavailable'); return original(account, force); };
  reply = () => new Response('{}', { status: calls.length === 1 ? 401 : 200 });
  assert.equal((await send(token)).status, 200); assert.equal(state.accounts()[0].status, 'ready'); assert.ok(state.accounts()[0].cooldown_until > Date.now());
});
test('an interrupted stream is never retried after its first content', async () => {
  const token = await register();
  reply = () => new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('event: content_block_delta\ndata: {"delta":{"text":"partial"}}\n\n')); setTimeout(() => controller.error(new Error('synthetic disconnect')), 80); } }), { headers: { 'content-type': 'text/event-stream' } });
  const response = await send(token, { stream: true }); const reader = response.body.getReader();
  assert.match(new TextDecoder().decode((await reader.read()).value), /partial/);
  await assert.rejects(reader.read());
  for (let attempt = 0; attempt < 100 && service.inFlight.size; attempt++) await wait(20);
  assert.equal(service.inFlight.size, 0, 'the failed request finished saving its state');
  assert.equal(calls.length, 1); assert.equal(state.read(state.sessionFile('session')).paused_reason, 'partial-response');
});
test('local artifacts and tool results are forwarded while unsupported documents fail before upstream', async () => {
  const token = await register();
  const messages = [{ role: 'user', content: 'Create a local report.' }, { role: 'assistant', content: [{ type: 'tool_use', id: 'tool_one', name: 'Write', input: { file_path: '/tmp/report.html', content: '<p>report</p>' } }] }, { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tool_one', content: 'Saved locally' }] }];
  assert.equal((await send(token, { messages, tools: [{ name: 'Write', input_schema: { type: 'object' } }] })).status, 200); assert.deepEqual(calls[0].messages, messages);
  await service.control('route', { action: 'use', model: 'openai/test', session: 'session' });
  const rejected = await send(token, { messages: [{ role: 'user', content: [{ type: 'document', source: {} }] }] });
  assert.equal(rejected.status, 503); assert.equal(calls.length, 1);
});
test('session state and its scoped route survive a stopped extension and re-registration', async () => {
  const token = await register(); await service.control('route', { action: 'use', model: 'openai/test', session: 'session' });
  await send(token, {}, { 'x-claude-code-session-id': 'conversation-one' });
  await service.control('finish', { id: 'session', token });
  const replacement = await register(); assert.equal((await send(token)).status, 401); assert.equal((await send(replacement, {}, { 'x-claude-code-session-id': 'conversation-one' })).status, 200);
  assert.equal(state.read(state.sessionFile('session')).conversation_id, 'conversation-one'); assert.equal(state.read(state.sessionFile('session')).current_model, 'openai/test');
});
test('a running client that clears or resumes moves its session to the new conversation', async () => {
  const token = await register();
  assert.equal((await send(token, {}, { 'x-claude-code-session-id': 'conversation-one' })).status, 200);
  assert.equal((await send(token, {}, { 'x-claude-code-session-id': 'conversation-one' })).status, 200);
  assert.equal((await send(token, {}, { 'x-claude-code-session-id': 'conversation-two' })).status, 200, 'after /clear the same launch keeps its route');
  assert.equal(state.read(state.sessionFile('session')).conversation_id, 'conversation-two');
  assert.equal((await send(token, {}, { 'x-claude-code-session-id': 'conversation-three', 'x-claude-code-parent-agent-id': 'agent-1' })).status, 200);
  assert.equal(state.read(state.sessionFile('session')).conversation_id, 'conversation-two', 'subagent requests do not rebind the conversation');
  const events = fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse).filter(event => event.type === 'route.conversation_changed');
  assert.deepEqual(events.map(event => [event.data.from, event.data.to]), [['conversation-one', 'conversation-two']]);
  assert.equal(calls.length, 4);
});
test('a fresh conversation at a reused Dex ID does not inherit the previous conversation or override', async () => {
  const token = await register(); await service.control('route', { action: 'use', model: 'openai/test', session: 'session' });
  await send(token, {}, { 'x-claude-code-session-id': 'conversation-one' });
  await service.control('finish', { id: 'session', token });
  const replacement = await register('session', { resume: false });
  const response = await send(replacement, {}, { 'x-claude-code-session-id': 'conversation-two' });
  assert.equal(response.status, 200, await response.text());
  assert.equal(state.read(state.sessionFile('session')).current_model, 'anthropic/test');
  assert.equal(state.read(state.sessionFile('session')).override, undefined);
});
