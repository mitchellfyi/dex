'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const ipc = require('../scripts/ccr/ipc.cjs');
const { createGatewayPlugin } = require('../scripts/ccr/core-plugin.cjs');

async function authenticate(t, body, sourceAdapterKey = 'anthropic_messages', provider = 'openai') {
  t.mock.method(ipc, 'call', async () => ({ headers: { authorization: 'Bearer synthetic' } }));
  const plugin = createGatewayPlugin().providerHooks.find(hook => hook.providerName === `dex-${provider}`);
  return plugin.authenticate({ sourceAdapterKey, request: { headers: { 'x-ccr-dex-account-ticket': 'synthetic-ticket' } },
    upstreamRequest: { headers: {}, body } });
}

test('Claude thinking becomes stateless reasoning summaries without losing text or tool history', async t => {
  const body = { input: [
    { type: 'reasoning', id: 'rs_generated', summary: [{ type: 'summary_text', text: 'Existing summary' }], content: [
      { type: 'reasoning_text', text: 'First thought' }, { type: 'reasoning_text', text: 'Second thought' }
    ] },
    { type: 'function_call', call_id: 'call_test', name: 'Bash', arguments: '{}' },
    { type: 'function_call_output', call_id: 'call_test', output: 'done' }
  ] };
  const original = structuredClone(body);
  const result = await authenticate(t, body);
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.body.input, [
    { type: 'reasoning', summary: ['Existing summary', 'First thought', 'Second thought'].map(text => ({ type: 'summary_text', text })) },
    ...body.input.slice(1)
  ]);
  assert.deepEqual(body, original);
});

test('native OpenAI reasoning and encrypted history retain their original fields', async t => {
  const input = [
    { type: 'reasoning', id: 'rs_native', summary: [], encrypted_content: 'synthetic-encrypted', content: [{ type: 'reasoning_text', text: 'Native thought' }] },
    { type: 'reasoning', id: 'rs_empty', summary: [], content: [] }
  ];
  assert.deepEqual((await authenticate(t, { input }, 'openai_responses')).value.body.input, input);
  assert.deepEqual((await authenticate(t, { input })).value.body.input, input);
});

test('Anthropic requests retain their thinking blocks and signatures', async t => {
  const body = { messages: [{ role: 'assistant', content: [{ type: 'thinking', thinking: 'A thought', signature: 'synthetic-signature' }] }] };
  assert.deepEqual((await authenticate(t, body, 'anthropic_messages', 'anthropic')).value.body, body);
});
