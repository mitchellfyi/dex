'use strict';
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
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

test('Codex reads a catalogue that mirrors the routed OpenAI model under the dex/active alias', async () => {
  const config = state.config(); config.native = { enabled: true }; config.phases[0] = { model: 'anthropic/test', fallbacks: ['openai/test'] }; state.write(state.stateFile('config'), config);
  const { token } = await service.control('native-auth', { client: 'codex', owner_pid: process.pid });
  const urls = [];
  const upstream = { slug: 'test', display_name: 'Test', description: 'upstream', default_reasoning_level: 'high', supported_reasoning_levels: [{ effort: 'high', description: 'h' }], shell_type: 'unified_exec', visibility: 'list', supported_in_api: true, priority: 3, upgrade: null, support_verbosity: true, default_verbosity: 'low', apply_patch_tool_type: 'freeform', truncation_policy: { mode: 'tokens', limit: 10000 }, supports_image_detail_original: true, context_window: 272000, max_context_window: 272000, experimental_supported_tools: [], model_messages: { instructions_template: 'upstream instructions' } };
  service.fetch = async url => { urls.push(url); return new Response(JSON.stringify({ models: [upstream, { slug: 'other', display_name: 'Other' }] })); };
  const catalogue = async (query = '?client_version=0.154.0', bearer = token) => fetch(endpoint.replace('/v1/messages', `/v1/models${query}`), { headers: { authorization: `Bearer ${bearer}` } });
  let response = await catalogue(); assert.equal(response.status, 200);
  let body = await response.json();
  assert.equal(body.models[0].slug, 'dex/active');
  assert.equal(body.models[0].display_name, 'Dex automatic route');
  assert.equal(body.models[0].apply_patch_tool_type, 'freeform');
  assert.equal(body.models[0].default_reasoning_level, 'high', 'metadata comes from the routed OpenAI model');
  assert.equal(body.models[0].model_messages.instructions_template, 'upstream instructions');
  assert.equal(body.models[0].context_window, 128000); assert.equal(body.models[0].max_context_window, 128000);
  assert.deepEqual(body.models.slice(1).map(item => item.slug), ['test', 'other']);
  assert.equal(refreshes.at(-1).id, 'three', 'the OpenAI account fetched the catalogue');
  assert.match(urls[0], /chatgpt\.com\/backend-api\/codex\/models\?client_version=0\.154\.0$/);
  await catalogue(); assert.equal(urls.length, 1, 'the upstream catalogue is cached');
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
  assert.equal((await send(token)).status, 503);
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
test('401 refreshes once before moving to another account', async () => {
  const token = await register(); reply = () => new Response('{}', { status: calls.length <= 2 ? 401 : 200 });
  assert.equal((await send(token)).status, 200);
  assert.deepEqual(refreshes.map(item => [item.id, Boolean(item.force)]), [['one', false], ['one', true], ['two', false]]);
  assert.equal(state.accounts()[0].status, 'reauth-required');
});
test('all exhausted accounts preserve route state without claiming a successful response', async () => {
  const token = await register(); reply = () => new Response('{}', { status: 429, headers: { 'retry-after': '60' } });
  const response = await send(token);
  assert.equal(response.status, 503); assert.equal(calls.length, 2);
  assert.ok(Number(response.headers.get('retry-after')) > 0);
  const error = (await response.json()).error;
  assert.equal(error.retry_after_seconds, Number(response.headers.get('retry-after')));
  assert.equal(error.code, 'subscription_accounts_unavailable');
  assert.match(error.message, /one: rate limited/);
  assert.match(error.message, /two: rate limited/);
  assert.doesNotMatch(error.message, /reauth/);
  assert.equal((await send(token)).status, 503); assert.equal(calls.length, 2, 'retries during cooldown do not call the provider');
  const session = state.read(state.sessionFile('session')); assert.equal(session.active, true); assert.equal(session.paused_reason, 'no-completed-response');
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
  assert.equal((await send(token, extra)).headers.get('x-dex-model'), 'anthropic/test', 'the primary model is retried when cooldown ends');
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
  assert.equal(response.status, 503); assert.equal(calls.length, 0);
  assert.equal(response.headers.get('retry-after'), null);
  const error = (await response.json()).error;
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
