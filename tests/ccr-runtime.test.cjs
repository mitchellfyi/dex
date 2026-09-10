'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const state = require('../scripts/ccr/state.cjs');
const ipc = require('../scripts/ccr/ipc.cjs');
const adapter = require('../scripts/ccr/adapter.cjs');
const { CredentialStore } = require('../scripts/ccr/accounts.cjs');

test('pinned CCR authenticates two accounts and translates OpenAI in the same session', { skip: !process.env.DEX_CCR_INTEGRATION_RUNTIME, timeout: 60000 }, async () => {
  process.env.DEX_ROUTER_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-runtime-'));
  const calls = [];
  const upstream = http.createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); calls.push({ url: req.url, headers: req.headers, body });
    if (req.headers.authorization === 'Bearer synthetic-a') {
      res.writeHead(429, { 'content-type': 'application/json', 'retry-after': '60' });
      res.end(JSON.stringify({ error: { type: 'rate_limit_error', message: 'Synthetic quota exhausted' } })); return;
    }
    if (req.url.includes('responses')) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      const response = { id: 'resp_test', object: 'response', status: 'completed', model: 'test-codex', output: [{ type: 'message', id: 'msg_test', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'OpenAI answer', annotations: [] }] }], usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8 } };
      for (const event of [{ type: 'response.created', response: { ...response, status: 'in_progress', output: [] } }, { type: 'response.output_item.added', output_index: 0, item: response.output[0] }, { type: 'response.content_part.added', item_id: 'msg_test', output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } }, { type: 'response.output_text.delta', item_id: 'msg_test', output_index: 0, content_index: 0, delta: 'OpenAI answer' }, { type: 'response.completed', response }]) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      res.end(); return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ id: 'msg_test', type: 'message', role: 'assistant', model: 'test-claude', content: [{ type: 'text', text: 'Claude answer' }], stop_reason: 'end_turn', stop_sequence: null, usage: { input_tokens: 5, output_tokens: 3 } }));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${upstream.address().port}`;
  const config = { version: 1, enabled: true, default_model: 'anthropic/test-claude', phases: {}, models: ['anthropic/test-claude', 'openai/test-codex'].map(id => ({ id, provider: id.split('/')[0], context_window: 200000, capabilities: { tools: true, images: true } })) };
  state.write(state.stateFile('config'), config);
  const accounts = ['a', 'b', 'c'].map((id, index) => ({ id, name: id, enabled: true, status: 'ready', provider: index < 2 ? 'anthropic' : 'openai', created_at: index }));
  state.saveAccounts(accounts);
  const store = new CredentialStore('linux');
  for (const account of accounts) store.set(account.id, { access_token: `synthetic-${account.id}`, refresh_token: 'synthetic-refresh', expires_at: Date.now() + 3600000, account_id: 'synthetic-account' });
  const extension = path.join(state.root(), 'fixture-extension.cjs');
  fs.writeFileSync(extension, `const { createExtension } = require(${JSON.stringify(path.resolve('scripts/ccr/extension.cjs'))}); const { AccountBroker, CredentialStore } = require(${JSON.stringify(path.resolve('scripts/ccr/accounts.cjs'))}); module.exports = createExtension({broker:new AccountBroker({store:new CredentialStore('linux')}),fetchImpl:async (...args)=>{const response=await fetch(...args);require('fs').appendFileSync(${JSON.stringify(path.join(state.root(), 'fixture-responses'))},await response.clone().text());return response;}});`);
  const token = state.token();
  try {
    const settings = await adapter.start({ directory: path.resolve(process.env.DEX_CCR_INTEGRATION_RUNTIME), endpoints: { anthropic: endpoint, openai: endpoint }, extension });
    const saved = await adapter.rpc(settings, 'getConfig');
    assert.equal(saved.APIKEYS?.some(key => key.key === settings.client_key), true, 'CCR retained the local transport key');
    await ipc.call('register', { id: 'test-session', token, owner_pid: process.pid });
    const send = () => fetch(`${settings.gateway}/plugins/dex/v1/messages`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', 'x-claude-code-session-id': 'conversation-one' }, body: JSON.stringify({ model: 'dex/active', max_tokens: 256, stream: false, messages: [{ role: 'user', content: 'hello' }] }) });
    let response = await send(); const first = await response.text();
    assert.equal(response.status, 200, first + (fs.existsSync(path.join(state.root(), 'fixture-responses')) ? fs.readFileSync(path.join(state.root(), 'fixture-responses'), 'utf8') : JSON.stringify(calls))); assert.match(first, /Claude answer/);
    assert.deepEqual(calls.map(call => call.headers.authorization), ['Bearer synthetic-a', 'Bearer synthetic-b']);
    assert.equal(state.accounts()[0].cooldown_until > Date.now(), true);
    await ipc.call('route', { action: 'use', model: 'openai/test-codex', session: 'test-session' });
    response = await send(); const second = await response.text();
    assert.equal(response.status, 200, second); assert.match(second, /OpenAI answer/);
    assert.equal(calls[2].headers.authorization, 'Bearer synthetic-c'); assert.match(calls[2].url, /responses/);
    assert.equal(calls[2].body.store, false); assert.equal(calls[2].headers['chatgpt-account-id'], 'synthetic-account');
    assert.equal(state.read(state.sessionFile('test-session')).conversation_id, 'conversation-one');
    for (const call of calls) assert.equal(call.headers['x-ccr-dex-account-ticket'], undefined);
    const events = fs.readFileSync(path.join(state.root(), 'events.jsonl'), 'utf8');
    assert.doesNotMatch(events, /synthetic-[abc]|synthetic-refresh/);
  } finally {
    try { await ipc.call('finish', { id: 'test-session', token }); } catch { /* Startup may have failed. */ }
    await adapter.stop(); await new Promise(resolve => upstream.close(resolve));
    fs.rmSync(state.root(), { recursive: true, force: true });
  }
});
