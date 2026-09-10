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
  assert.equal((await send(token)).status, 503); assert.equal(calls.length, 2);
  const session = state.read(state.sessionFile('session')); assert.equal(session.active, true); assert.equal(session.paused_reason, 'no-completed-response');
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
  await assert.rejects(reader.read()); await wait(100);
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
