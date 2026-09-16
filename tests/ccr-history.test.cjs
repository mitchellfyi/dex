'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { prepareHistory, restoreAnthropic, prepareResponse } = require('../scripts/ccr/history.cjs');

const encrypted = `ccr-openai-responses-reasoning-v1:${Buffer.from(JSON.stringify({ id: 'rs_test', encrypted_content: 'synthetic-openai' })).toString('base64url')}`;
const claude = { type: 'thinking', thinking: 'Check the file.', signature: 'synthetic-claude' };
const omitted = { type: 'thinking', thinking: '', signature: 'synthetic-omitted' };
const redacted = { type: 'redacted_thinking', data: 'synthetic-anthropic' };
const openai = { type: 'redacted_thinking', data: encrypted };
const summary = { type: 'thinking', thinking: 'Check the test.', cache_control: { type: 'ephemeral' } };
const tool = { type: 'tool_use', id: 'call_test', name: 'Read', input: { file: 'fake.txt' } };
const text = { type: 'text', text: 'Checking.' };
const body = { messages: [
  { role: 'user', content: 'Check this fake file.' },
  { role: 'assistant', content: [claude, omitted, redacted, openai, summary, text, tool] },
  { role: 'user', content: [{ type: 'tool_result', tool_use_id: tool.id, content: 'fake contents' }] }
] };

test('mixed Messages history can move to either provider without changing the saved history', () => {
  for (const provider of ['anthropic', 'openai', 'anthropic', 'openai']) {
    const outgoing = structuredClone(body);
    prepareHistory(outgoing, provider, 'messages');
    assert.deepEqual(outgoing.messages[0], body.messages[0]);
    assert.deepEqual(outgoing.messages[2], body.messages[2]);
    assert.deepEqual(outgoing.messages[1].content, provider === 'anthropic'
      ? [claude, omitted, redacted, { type: 'text', text: summary.thinking, cache_control: summary.cache_control }, text, tool]
      : [claude, openai, summary, text, tool]);
  }
  assert.deepEqual(body.messages[1].content, [claude, omitted, redacted, openai, summary, text, tool]);
});

test('opaque-only assistant messages are omitted only from the incompatible outgoing request', () => {
  for (const [provider, block] of [['anthropic', openai], ['openai', redacted], ['openai', omitted]]) {
    const outgoing = { messages: [body.messages[0], { role: 'assistant', content: [block] }, { role: 'user', content: 'Continue.' }] };
    prepareHistory(outgoing, provider, 'messages');
    assert.deepEqual(outgoing.messages, [body.messages[0], { role: 'user', content: 'Continue.' }]);
  }
});

test('Responses history preserves tools and readable reasoning when moving to Claude', () => {
  const source = { input: [
    { role: 'user', content: 'Check the fake file.' },
    { type: 'reasoning', id: 'rs_opaque', encrypted_content: 'synthetic-private', summary: [] },
    { type: 'reasoning', id: 'rs_summary', encrypted_content: 'synthetic-private', summary: [{ type: 'summary_text', text: 'Check permissions.' }], content: [{ type: 'reasoning_text', text: 'Then read it.' }] },
    { type: 'function_call', id: 'fc_test', call_id: tool.id, name: tool.name, arguments: JSON.stringify(tool.input) },
    { type: 'function_call_output', call_id: tool.id, output: 'fake contents' }
  ] };
  const outgoing = structuredClone(source);
  prepareHistory(outgoing, 'anthropic', 'responses');
  assert.deepEqual(outgoing.input, [source.input[0], { role: 'assistant', content: [{ type: 'output_text', text: 'Check permissions.\nThen read it.' }] }, ...source.input.slice(3)]);
  const native = structuredClone(source);
  prepareHistory(native, 'openai', 'responses');
  assert.deepEqual(native, source);
});

const claudeItem = { type: 'reasoning', id: 'rs_claude', summary: [],
  content: [{ type: 'reasoning_text', text: 'Check café permissions.' }],
  encrypted_content: redacted.data, reasoning_details: [claude, redacted] };
async function convert(value, streaming, chunkSize = 7) {
  const payload = Buffer.from(streaming ? `event: response.completed\r\ndata: ${JSON.stringify(value)}\r\n\r\ndata: [DONE]\n\n` : JSON.stringify(value));
  async function* chunks() { for (let offset = 0; offset < payload.length; offset += chunkSize) yield payload.subarray(offset, offset + chunkSize); }
  let result = '';
  for await (const chunk of prepareResponse(chunks(), streaming ? 'text/event-stream' : 'application/json')) result += chunk;
  return streaming ? JSON.parse(result.split('\n').find(line => line.startsWith('data: ')).slice(6)) : JSON.parse(result);
}

for (const streaming of [false, true]) test(`Claude signatures survive native Responses history (${streaming ? 'stream' : 'JSON'})`, async () => {
  const event = { type: 'response.completed', response: { output: [claudeItem, { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Answer.' }] }] } };
  for (const chunkSize of [1, 17, 100000]) {
    const result = await convert(event, streaming, chunkSize);
    const item = result.response.output[0];
    assert.equal(item.reasoning_details, undefined);
    assert.equal(item.content, undefined);
    assert.deepEqual(item.summary, [{ type: 'summary_text', text: 'Check café permissions.' }]);
    assert.deepEqual(result.response.output[1], event.response.output[1]);
    // Codex retains standard fields only when it stores a response item.
    const saved = { type: item.type, id: item.id, summary: item.summary, encrypted_content: item.encrypted_content };
    for (const provider of ['openai', 'anthropic', 'openai', 'anthropic']) {
      const next = { input: [structuredClone(saved)] }; prepareHistory(next, provider, 'responses');
      if (provider === 'openai') assert.deepEqual(next.input, [{ role: 'assistant', content: [{ type: 'output_text', text: 'Check café permissions.' }] }]);
      else {
        const upstream = { messages: [{ role: 'assistant', content: [{ type: 'redacted_thinking', data: next.input[0].encrypted_content }] }] };
        restoreAnthropic(upstream);
        assert.deepEqual(upstream.messages[0].content, [claude, redacted]);
      }
    }
  }
  assert.deepEqual(claudeItem.reasoning_details, [claude, redacted]);
});

test('legacy CCR Responses signatures are restored through the provider hook', () => {
  const body = { input: [structuredClone(claudeItem)] };
  prepareHistory(body, 'anthropic', 'responses');
  const upstream = { messages: [{ role: 'assistant', content: [{ type: 'redacted_thinking', data: body.input[0].encrypted_content }] }] };
  restoreAnthropic(upstream);
  assert.deepEqual(upstream.messages[0].content, [claude, redacted]);
});

test('native reasoning and unrelated streaming events remain unchanged', async () => {
  const event = { type: 'response.completed', response: { output: [{ type: 'reasoning', id: 'rs_native', summary: [], encrypted_content: 'native' }, { type: 'function_call', call_id: 'call_one', name: 'read', arguments: '{}' }] } };
  assert.deepEqual(await convert(event, true), event);
  assert.deepEqual(await convert({ type: 'response.output_text.delta', delta: 'café' }, true), { type: 'response.output_text.delta', delta: 'café' });
  const added = await convert({ type: 'response.output_item.done', item: claudeItem }, true);
  assert.match(added.item.encrypted_content, /^dex-anthropic-messages-reasoning-v1:/);
});

test('malformed private reasoning and truncated streams fail without forwarding invalid blocks', async () => {
  const data = 'dex-anthropic-messages-reasoning-v1:' + Buffer.from('[{"type":"tool_use"}]').toString('base64url');
  assert.throws(() => prepareHistory({ input: [{ type: 'reasoning', encrypted_content: data }] }, 'openai', 'responses'), /Invalid Claude reasoning/);
  await assert.rejects(async () => { for await (const _chunk of prepareResponse([Buffer.from('data: {')], 'text/event-stream')) { /* Drain the stream to observe truncation. */ } }, /ended before/);
});
