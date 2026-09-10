'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const state = require('../scripts/ccr/state.cjs');
const ipc = require('../scripts/ccr/ipc.cjs');
const adapter = require('../scripts/ccr/adapter.cjs');
const { CredentialStore } = require('../scripts/ccr/accounts.cjs');

test('pinned CCR authenticates two accounts and translates OpenAI in the same session', { skip: !process.env.DEX_CCR_INTEGRATION_RUNTIME, timeout: 60000 }, async () => {
  process.env.DEX_ROUTER_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-runtime-'));
  const calls = [];
  let secondLimited = false;
  const upstream = http.createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); calls.push({ url: req.url, headers: req.headers, body });
    if (req.headers.authorization === 'Bearer synthetic-a' || (secondLimited && req.headers.authorization === 'Bearer synthetic-b')) {
      res.writeHead(429, { 'content-type': 'application/json', 'retry-after': '60' });
      res.end(JSON.stringify({ error: { type: 'rate_limit_error', message: 'Synthetic quota exhausted' } })); return;
    }
    if (req.url.includes('responses')) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      if (body.tools?.some(tool => tool.name === 'dex_test_write')) {
        const item = { id: 'fc_test', call_id: 'call_test', type: 'function_call', name: 'dex_test_write', arguments: '{"file":"report.html"}', status: 'completed' };
        const response = { id: 'resp_tool', object: 'response', model: 'test-codex', status: 'completed', output: [item], usage: { input_tokens: 5, output_tokens: 8, total_tokens: 13 } };
        for (const event of [{ type: 'response.created', response: { ...response, status: 'in_progress', output: [] } }, { type: 'response.output_item.added', output_index: 0, item: { ...item, arguments: '' } }, { type: 'response.function_call_arguments.delta', item_id: 'fc_test', output_index: 0, delta: item.arguments }, { type: 'response.function_call_arguments.done', item_id: 'fc_test', output_index: 0, arguments: item.arguments }, { type: 'response.output_item.done', output_index: 0, item }, { type: 'response.completed', response }]) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
        res.end(); return;
      }
      const response = { id: 'resp_test', object: 'response', status: 'completed', model: 'test-codex', output: [{ type: 'message', id: 'msg_test', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'OpenAI answer', annotations: [] }] }], usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8 } };
      for (const event of [{ type: 'response.created', response: { ...response, status: 'in_progress', output: [] } }, { type: 'response.output_item.added', output_index: 0, item: response.output[0] }, { type: 'response.content_part.added', item_id: 'msg_test', output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } }, { type: 'response.output_text.delta', item_id: 'msg_test', output_index: 0, content_index: 0, delta: 'OpenAI answer' }, { type: 'response.completed', response }]) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      res.end(); return;
    }
    const message = { id: 'msg_test', type: 'message', role: 'assistant', model: 'test-claude', content: [{ type: 'text', text: 'Claude answer' }], stop_reason: 'end_turn', stop_sequence: null, usage: { input_tokens: 5, output_tokens: 3 } };
    if (body.stream) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      for (const event of [{ type: 'message_start', message: { ...message, content: [], stop_reason: null } }, { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Claude answer' } }, { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 3 } }, { type: 'message_stop' }]) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      res.end(); return;
    }
    res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(message));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${upstream.address().port}`;
  const config = { version: 1, enabled: true, default_model: 'anthropic/test-claude', phases: {}, models: ['anthropic/test-claude', 'openai/test-codex'].map(id => ({ id, provider: id.split('/')[0], context_window: 200000, capabilities: { tools: true, images: true } })) };
  state.write(state.stateFile('config'), config);
  const accounts = ['a', 'b', 'c'].map((id, index) => ({ id, name: id, enabled: true, status: 'ready', provider: index < 2 ? 'anthropic' : 'openai', created_at: index, usage: { observed_at: Date.now(), source: 'provider', confidence: 'provider-derived', windows: [{ name: '5h', remaining_ratio: 0.6, resets_at: Date.now() + 3600000 }] } }));
  state.saveAccounts(accounts);
  const store = new CredentialStore('linux');
  for (const account of accounts) store.set(account.id, { access_token: `synthetic-${account.id}`, refresh_token: 'synthetic-refresh', expires_at: Date.now() + 3600000, account_id: 'synthetic-account' });
  const extension = path.join(state.root(), 'fixture-extension.cjs');
  fs.writeFileSync(extension, `const { createExtension } = require(${JSON.stringify(path.resolve('scripts/ccr/extension.cjs'))}); const { AccountBroker, CredentialStore } = require(${JSON.stringify(path.resolve('scripts/ccr/accounts.cjs'))}); module.exports = createExtension({broker:new AccountBroker({store:new CredentialStore('linux')})});`);
  const token = state.token();
  try {
    const settings = await adapter.start({ directory: path.resolve(process.env.DEX_CCR_INTEGRATION_RUNTIME), endpoints: { anthropic: endpoint, openai: endpoint }, extension });
    const saved = await adapter.rpc(settings, 'getConfig');
    assert.equal(saved.APIKEYS?.some(key => key.key === settings.client_key), true, 'CCR retained the local transport key');
    const runRoot = path.join(state.root(), 'runs');
    await ipc.call('register', { id: 'test-session', token, owner_pid: process.pid, run_id: 'run_ccr_test', run_root: runRoot });
    const send = (body = {}) => fetch(`${settings.gateway}/plugins/dex/v1/messages`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', 'x-claude-code-session-id': 'conversation-one' }, body: JSON.stringify({ model: 'dex/active', max_tokens: 256, stream: false, messages: [{ role: 'user', content: 'hello' }], ...body }) });
    let response = await send(); const first = await response.text();
    assert.equal(response.status, 200, first); assert.match(first, /Claude answer/);
    assert.deepEqual(calls.map(call => call.headers.authorization), ['Bearer synthetic-a', 'Bearer synthetic-b']);
    assert.equal(state.accounts()[0].cooldown_until > Date.now(), true);
    await ipc.call('route', { action: 'use', model: 'openai/test-codex', session: 'test-session' });
    response = await send(); const second = await response.text();
    assert.equal(response.status, 200, second); assert.match(second, /OpenAI answer/);
    assert.equal(calls[2].headers.authorization, 'Bearer synthetic-c'); assert.match(calls[2].url, /responses/);
    assert.equal(calls[2].body.store, false); assert.equal(calls[2].headers['chatgpt-account-id'], 'synthetic-account');
    const toolResponse = await send({ tools: [{ name: 'dex_test_write', description: 'Write a local report', input_schema: { type: 'object', properties: { file: { type: 'string' } }, required: ['file'] } }] });
    const toolMessage = await toolResponse.json();
    assert.equal(toolResponse.status, 200, JSON.stringify(toolMessage));
    const tool = toolMessage.content.find(block => block.type === 'tool_use');
    assert.equal(tool.name, 'dex_test_write'); assert.equal(tool.input.file, 'report.html');
    const followup = await send({ messages: [{ role: 'user', content: 'Create report' }, { role: 'assistant', content: [tool] }, { role: 'user', content: [{ type: 'tool_result', tool_use_id: tool.id, content: 'Saved locally' }] }] });
    assert.equal(followup.status, 200); await followup.text();
    assert.ok(calls.at(-1).body.input.some(item => item.type === 'function_call_output' && item.output === 'Saved locally'));
    assert.equal(state.read(state.sessionFile('test-session')).conversation_id, 'conversation-one');
    for (const call of calls) assert.equal(call.headers['x-ccr-dex-account-ticket'], undefined);
    const events = fs.readFileSync(path.join(state.root(), 'events.jsonl'), 'utf8');
    assert.doesNotMatch(events, /synthetic-[abc]|synthetic-refresh/);
    const snapshots = await adapter.rpc(settings, 'getProviderAccountSnapshots');
    assert.match(JSON.stringify(snapshots), /a-5h/);
    await assert.rejects(adapter.stop(), /sessions are active/);
    await adapter.stopOwned(settings);
    const recovered = await adapter.start({ recovery: true, endpoints: { anthropic: endpoint, openai: endpoint }, extension });
    assert.equal(recovered.gateway, settings.gateway); assert.equal(recovered.client_key, settings.client_key);
    response = await send(); assert.equal(response.status, 200, await response.text());
    assert.equal(state.read(state.sessionFile('test-session')).conversation_id, 'conversation-one');
    const journal = path.join(runRoot, 'run_ccr_test', 'events.jsonl');
    for (let attempt = 0; attempt < 100 && !fs.existsSync(journal); attempt++) await new Promise(resolve => setTimeout(resolve, 25));
    assert.match(fs.readFileSync(journal, 'utf8'), /account.failover/);
    assert.doesNotMatch(fs.readFileSync(state.stateFile('backend'), 'utf8'), new RegExp(settings.client_key));
    if (process.env.DEX_CCR_NATIVE_CLAUDE === '1') {
      const nativeHome = state.privateDir(path.join(state.root(), 'native-claude'));
      const env = { ...process.env, DEX_DIR: path.resolve('.'), CLAUDE_CONFIG_DIR: nativeHome, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1' };
      for (const key of ['DEX_SESSION_ID', 'DEX_RUN_ID', 'DX_ROUTER_SESSION_ID', 'DX_MODEL_OVERRIDE', 'DX_CLAUDE_MODEL', 'DEX_PHASE_HANDOFF']) delete env[key];
      const child = spawn(process.execPath, [path.resolve('scripts/ccr/cli.cjs'), 'launch', '--', '-p', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json'], { cwd: nativeHome, env, stdio: ['pipe', 'pipe', 'pipe'], timeout: 30000 });
      let pending = ''; let errors = ''; const results = []; let exited = false;
      child.stdout.on('data', chunk => { pending += chunk; let boundary; while ((boundary = pending.indexOf('\n')) >= 0) { const line = pending.slice(0, boundary); pending = pending.slice(boundary + 1); try { const event = JSON.parse(line); if (event.type === 'result') results.push(event); } catch { /* Native informational output is not a model result. */ } } });
      child.stderr.on('data', chunk => { errors += chunk; });
      const completion = new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', code => { exited = true; resolve(code); }); });
      const waitForResult = async number => {
        for (let attempt = 0; attempt < 400 && results.length < number && !exited; attempt++) await new Promise(resolve => setTimeout(resolve, 50));
        assert.ok(results.length >= number, `Native Claude did not complete turn ${number}: ${errors} ${pending}`); return results[number - 1];
      };
      try {
        child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: 'Say hello.' } })}\n`);
        const first = await waitForResult(1); assert.match(first.result, /Claude answer/);
        const routed = state.sessions().find(session => session.owner_pid === child.pid && session.active);
        assert.ok(routed); await ipc.call('route', { session: routed.id, action: 'use', model: 'openai/test-codex' });
        child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: 'Say hello again.' } })}\n`);
        const second = await waitForResult(2); assert.match(second.result, /OpenAI answer/);
        assert.equal(first.session_id, second.session_id);
        child.stdin.end(); assert.equal(await completion, 0, errors);
      } finally { if (!exited) { child.kill('SIGTERM'); await completion; } }
    }
    config.phases[0] = { model: 'anthropic/test-claude', fallbacks: ['openai/test-codex'] }; state.write(state.stateFile('config'), config);
    await ipc.call('route', { session: 'test-session', action: 'auto' }); secondLimited = true;
    const fallback = await send(); assert.equal(fallback.status, 200); assert.match(await fallback.text(), /OpenAI answer/);
    assert.deepEqual(calls.slice(-2).map(call => call.headers.authorization), ['Bearer synthetic-b', 'Bearer synthetic-c']);
  } finally {
    try { await ipc.call('finish', { id: 'test-session', token }); } catch { /* Startup may have failed. */ }
    await adapter.stop(); await new Promise(resolve => upstream.close(resolve));
    fs.rmSync(state.root(), { recursive: true, force: true });
  }
});
