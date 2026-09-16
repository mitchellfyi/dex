'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn, spawnSync } = require('node:child_process');
const state = require('../scripts/ccr/state.cjs');
const ipc = require('../scripts/ccr/ipc.cjs');
const adapter = require('../scripts/ccr/adapter.cjs');
const { CredentialStore } = require('../scripts/ccr/accounts.cjs');

test('pinned CCR authenticates two accounts and translates OpenAI in the same session', { skip: !process.env.DEX_CCR_INTEGRATION_RUNTIME, timeout: 180000 }, async () => {
  process.env.DEX_ROUTER_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-runtime-'));
  const calls = [];
  let secondLimited = false, allLimited = false, contextExceeded = false;
  const upstream = http.createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); calls.push({ url: req.url, headers: req.headers, body });
    if (body.input?.some(item => item.type === 'reasoning' && (item.content?.length || (item.id && !item.encrypted_content)))) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { type: 'invalid_request_error', code: 'array_above_max_length', param: 'input[1].content' } })); return;
    }
    if (contextExceeded) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { code: 'context_length_exceeded', type: 'invalid_request_error', message: 'Synthetic context limit' } })); return;
    }
    if (allLimited || (body.model !== 'test-opus' && (req.headers.authorization === 'Bearer synthetic-a' || (secondLimited && req.headers.authorization === 'Bearer synthetic-b')))) {
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
    const message = { id: 'msg_test', type: 'message', role: 'assistant', model: body.model, content: [{ type: 'text', text: 'Claude answer' }], stop_reason: 'end_turn', stop_sequence: null, usage: { input_tokens: 5, output_tokens: 3 } };
    if (JSON.stringify(body.messages).includes('synthetic-compaction-fixture')) message.usage.input_tokens = 12000;
    if (body.stream) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      for (const event of [{ type: 'message_start', message: { ...message, content: [], stop_reason: null } }, { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Claude answer' } }, { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 3 } }, { type: 'message_stop' }]) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      res.end(); return;
    }
    res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(message));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${upstream.address().port}`;
  const config = { version: 1, enabled: true, default_model: 'anthropic/test-claude', phases: {}, models: ['anthropic/test-claude', 'openai/test-codex', 'anthropic/test-opus'].map(id => ({ id, provider: id.split('/')[0], context_window: 200000, capabilities: { tools: true, images: true } })) };
  config.models.push({ id: 'openai/test-small', provider: 'openai', context_window: 64000, capabilities: { tools: true, images: true } });
  state.write(state.stateFile('config'), config);
  const accounts = ['a', 'b', 'c'].map((id, index) => ({ id, name: id, enabled: true, status: 'ready', provider: index < 2 ? 'anthropic' : 'openai', created_at: index, usage: { observed_at: Date.now(), source: 'provider', confidence: 'provider-derived', windows: [{ name: '5h', remaining_ratio: 0.6, resets_at: Date.now() + 3600000 }] } }));
  state.saveAccounts(accounts);
  const store = new CredentialStore('linux');
  for (const account of accounts) store.set(account.id, { access_token: `synthetic-${account.id}`, refresh_token: 'synthetic-refresh', expires_at: Date.now() + 3600000, account_id: 'synthetic-account' });
  const extension = path.join(state.root(), 'fixture-extension.cjs');
  fs.writeFileSync(extension, [
    `const { createExtension } = require(${JSON.stringify(path.resolve('scripts/ccr/extension.cjs'))});`,
    `const { AccountBroker, CredentialStore } = require(${JSON.stringify(path.resolve('scripts/ccr/accounts.cjs'))});`,
    "const broker = new AccountBroker({store:new CredentialStore('linux'), fetchImpl:async () => { throw new Error('Unexpected external request in the runtime fixture'); }});",
    'broker.usage = async account => ({ ...account.usage, observed_at: Date.now() });',
    'module.exports = createExtension({broker});'
  ].join('\n'));
  const token = state.token();
  try {
    const settings = await adapter.start({ directory: path.resolve(process.env.DEX_CCR_INTEGRATION_RUNTIME), endpoints: { anthropic: endpoint, openai: endpoint }, extension });
    const saved = await adapter.rpc(settings, 'getConfig');
    assert.equal(saved.APIKEYS?.some(key => key.key === settings.client_key), true, 'CCR retained the local transport key');
    state.saveAccounts(state.accounts().map(account => ({ ...account, usage: { ...account.usage, observed_at: 0 } })));
    const refreshed = await ipc.call('usage');
    assert.ok(refreshed.every(account => account.status === 'ready' && account.usage.observed_at > 0 && !account.usage_error), 'expired fixture quota stays local and does not invalidate synthetic logins');
    const runRoot = path.join(state.root(), 'runs');
    await ipc.call('register', { id: 'test-session', token, owner_pid: process.pid, run_id: 'run_ccr_test', run_root: runRoot });
    const send = (body = {}) => fetch(`${settings.gateway}/plugins/dex/v1/messages`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', 'x-claude-code-session-id': 'conversation-one' }, body: JSON.stringify({ model: 'dex/active', max_tokens: 256, stream: false, messages: [{ role: 'user', content: 'hello' }], ...body }) });
    let response = await send(); const first = await response.text();
    assert.equal(response.status, 200, first); assert.match(first, /Claude answer/);
    assert.deepEqual(calls.map(call => call.headers.authorization), ['Bearer synthetic-a', 'Bearer synthetic-b']);
    assert.equal(state.accounts()[0].model_cooldowns['anthropic/test-claude'] > Date.now(), true);
    assert.equal(state.accounts()[0].cooldown_until, undefined);
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
    config.phases[0] = { model: 'openai/test-codex', effort: 'xhigh' }; state.write(state.stateFile('config'), config);
    await ipc.call('route', { action: 'auto', session: 'test-session' });
    const thinkingResponse = await send({ output_config: { effort: 'high' }, messages: [
      { role: 'user', content: 'Create report' },
      { role: 'assistant', content: [{ type: 'thinking', thinking: 'Check the report first.', signature: 'synthetic-signature' }, tool] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: tool.id, content: 'Saved locally' }] }
    ] });
    assert.equal(thinkingResponse.status, 200, await thinkingResponse.text());
    const reasoning = calls.at(-1).body.input.find(item => item.type === 'reasoning');
    assert.deepEqual(reasoning, { type: 'reasoning', summary: [{ type: 'summary_text', text: 'Check the report first.' }] });
    assert.equal(calls.at(-1).body.reasoning.effort, 'xhigh');
    assert.ok(calls.at(-1).body.input.some(item => item.type === 'function_call_output' && item.call_id === tool.id));
    delete config.phases[0]; state.write(state.stateFile('config'), config);
    config.native = { enabled: true }; state.write(state.stateFile('config'), config);
    const native = await ipc.call('native-auth', { client: 'codex', owner_pid: process.pid });
    const sendResponses = body => fetch(`${settings.gateway}/plugins/dex/v1/responses`, { method: 'POST', headers: { authorization: `Bearer ${native.token}`, 'content-type': 'application/json' }, body: JSON.stringify({ model: 'dex/active', stream: true, input: [{ role: 'user', content: [{ type: 'input_text', text: 'hello' }] }], ...body }) });
    const nativeClaude = await sendResponses(); const nativeClaudeStream = await nativeClaude.text();
    assert.equal(nativeClaude.status, 200, nativeClaudeStream);
    assert.match(nativeClaudeStream, /response.completed/); assert.match(nativeClaudeStream, /Claude answer/);
    // Codex was launched at the 200k route budget; a 64k model is still selectable by /model and by dx route use.
    assert.equal(state.read(state.sessionFile(`native-codex-${process.pid}`)).context_limit, 200000);
    const smaller = await sendResponses({ model: 'test-small' }); const smallerStream = await smaller.text();
    assert.equal(smaller.status, 200, smallerStream); assert.match(smallerStream, /OpenAI answer/);
    assert.equal(smaller.headers.get('x-dex-model'), 'openai/test-small'); assert.equal(calls.at(-1).body.model, 'test-small');
    await ipc.call('route', { session: `native-codex-${process.pid}`, action: 'use', model: 'openai/test-small' });
    const smallerRoute = await sendResponses(); assert.equal(smallerRoute.status, 200, await smallerRoute.text());
    assert.equal(smallerRoute.headers.get('x-dex-model'), 'openai/test-small');
    await ipc.call('route', { session: `native-codex-${process.pid}`, action: 'use', model: 'openai/test-codex' });
    contextExceeded = true;
    const contextError = await sendResponses();
    assert.equal(contextError.status, 400);
    assert.equal((await contextError.json()).error.code, 'context_length_exceeded');
    contextExceeded = false;
    const nativeTool = await sendResponses({ tools: [{ type: 'function', name: 'dex_test_write', description: 'Write a report', parameters: { type: 'object', properties: { file: { type: 'string' } } } }] });
    const nativeToolStream = await nativeTool.text(); assert.equal(nativeTool.status, 200, nativeToolStream);
    assert.match(nativeToolStream, /response.function_call_arguments.delta/); assert.match(nativeToolStream, /dex_test_write/);
    const nativeFollowup = await sendResponses({ input: [{ type: 'function_call', call_id: 'call_test', name: 'dex_test_write', arguments: '{"file":"report.html"}' }, { type: 'function_call_output', call_id: 'call_test', output: 'Saved by native Codex' }] });
    assert.equal(nativeFollowup.status, 200, await nativeFollowup.text());
    assert.ok(calls.at(-1).body.input.some(item => item.type === 'function_call_output' && item.output === 'Saved by native Codex'));
    await ipc.call('finish', { id: `native-codex-${process.pid}`, token: native.token });
    if (process.env.DEX_CCR_NATIVE_CLIENTS === '1') {
      const nativeHome = state.privateDir(path.join(state.root(), 'native-clients'));
      const nativeConfig = { claude_file: path.join(nativeHome, 'claude/settings.json'), codex_file: path.join(nativeHome, 'codex/config.toml') };
      require('../scripts/ccr/native.cjs').clientSettings('enable', nativeConfig, settings);
      const env = { ...process.env, DEX_DIR: path.resolve('.'), CODEX_HOME: path.dirname(nativeConfig.codex_file), CLAUDE_CONFIG_DIR: path.dirname(nativeConfig.claude_file), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DEX_SESSION_ONLY: '1', DX_PROVIDER_PROFILE: 'codex-subscription', TERM: 'xterm-256color', DX_STATE_DIR: path.join(nativeHome, 'phases'), DX_LOOP_DIR: path.join(nativeHome, 'loops') };
      for (const key of Object.keys(env)) if (/^(ANTHROPIC_|OPENAI_|DEX_LOOP_|DEX_REVIEW_|DEX_PHASE_|DX_MODEL|DX_CLAUDE_|DX_CODEX_|CLAUDE_CODE_OAUTH_TOKEN)/.test(key) || ['DEX_SESSION_ID', 'DEX_RUN_ID', 'DX_ROUTER_SESSION_ID', 'DX_ROUTER_SESSION_TOKEN', 'CLAUDECODE'].includes(key)) delete env[key];
      const runNative = (executable, args) => new Promise((resolve, reject) => {
        const child = spawn(executable, args, { cwd: nativeHome, env, stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 });
        let stdout = ''; let stderr = '';
        child.stdout.on('data', chunk => { stdout += chunk; }); child.stderr.on('data', chunk => { stderr += chunk; });
        child.on('error', reject); child.on('exit', code => code === 0 ? resolve(stdout) : reject(new Error(`Native client failed (${code}): ${stderr} ${stdout}`)));
      });
      assert.match(await runNative('claude', ['--dangerously-skip-permissions', '--permission-mode', 'bypassPermissions', '-p', 'Say hello.', '--no-session-persistence']), /Claude answer/);
      const claims = Buffer.from(JSON.stringify({ sub: 'synthetic-user', exp: Math.floor(Date.now() / 1000) + 3600, 'https://api.openai.com/auth': { chatgpt_account_id: 'synthetic-account', chatgpt_plan_type: 'plus' } })).toString('base64url');
      state.write(path.join(env.CODEX_HOME, 'auth.json'), { auth_mode: 'chatgpt', tokens: { id_token: `e30.${claims}.c3ludGhldGlj`, access_token: 'synthetic-native', refresh_token: 'synthetic-refresh', account_id: 'synthetic-account' }, last_refresh: new Date().toISOString() });
      const initialized = spawnSync('git', ['init', '-q', nativeHome]); assert.equal(initialized.status, 0);
      fs.appendFileSync(nativeConfig.codex_file, `\n[projects.${JSON.stringify(fs.realpathSync(nativeHome))}]\ntrust_level = "trusted"\n`);
      assert.match(await runNative('python3', [path.resolve('tests/ccr-codex-smoke.py')]), /Native Codex received/);
      const beforeCompaction = fs.readFileSync(nativeConfig.codex_file, 'utf8');
      fs.writeFileSync(nativeConfig.codex_file, beforeCompaction.replace(/^model_auto_compact_token_limit = \d+$/m, 'model_auto_compact_token_limit = 5000'));
      assert.match(await runNative('python3', [path.resolve('tests/ccr-codex-smoke.py'), '--compact']), /automatically compacted and continued/);
      fs.writeFileSync(nativeConfig.codex_file, beforeCompaction);
      require('../scripts/ccr/native.cjs').clientSettings('disable', nativeConfig, settings);
    }
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
    config.phases[0].fallbacks = ['anthropic/test-opus']; state.write(state.stateFile('config'), config);
    const sameProviderFallback = await send();
    assert.equal(sameProviderFallback.status, 200); assert.match(await sameProviderFallback.text(), /Claude answer/);
    assert.equal(sameProviderFallback.headers.get('x-dex-model'), 'anthropic/test-opus');
    assert.equal(calls.at(-1).body.model, 'test-opus');
    await ipc.call('native-auth', { client: 'codex', owner_pid: process.pid });
    const nativeFallback = await sendResponses();
    assert.equal(nativeFallback.status, 200); assert.match(await nativeFallback.text(), /Claude answer/);
    assert.equal(nativeFallback.headers.get('x-dex-model'), 'anthropic/test-opus');
    await ipc.call('finish', { id: `native-codex-${process.pid}`, token: native.token });
    allLimited = true;
    for (let attempt = 0; attempt < 2; attempt++) {
      const unavailable = await send(); const error = (await unavailable.json()).error;
      assert.equal(unavailable.status, 429);
      assert.equal(error.type, 'rate_limit_error');
      assert.ok(Number(unavailable.headers.get('retry-after')) > 0);
      assert.equal(error.retry_after_seconds, Number(unavailable.headers.get('retry-after')));
      assert.match(error.message, /test-claude:.*rate limited.*test-opus:.*rate limited/);
      assert.doesNotMatch(error.message, /reauth/);
    }
    allLimited = false;
    config.phases[0].fallbacks = ['openai/test-codex']; state.write(state.stateFile('config'), config);
    await ipc.call('finish', { id: 'test-session', token });
    await adapter.stop();
    const previousKey = settings.client_key;
    const restarted = await adapter.start({ directory: path.resolve(process.env.DEX_CCR_INTEGRATION_RUNTIME), endpoints: { anthropic: endpoint, openai: endpoint }, extension });
    assert.notEqual(restarted.client_key, previousKey);
    Object.assign(settings, restarted);
    await ipc.call('register', { id: 'test-session', token, owner_pid: process.pid, resume: true });
    const afterRestart = await send();
    assert.equal(afterRestart.status, 200); assert.match(await afterRestart.text(), /OpenAI answer/);
  } finally {
    try { await ipc.call('finish', { id: 'test-session', token }); } catch { /* Startup may have failed. */ }
    await adapter.stopOwned(state.backend(null));
    upstream.closeAllConnections();
    await new Promise(resolve => upstream.close(resolve));
    fs.rmSync(state.root(), { recursive: true, force: true });
  }
});
