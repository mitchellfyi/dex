'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Readable, Writable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const metrics = require('../scripts/ccr/metrics.cjs');
const { responseMetrics, providerRequestId } = metrics;
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cli = require('../scripts/ccr/cli.cjs');
const adapter = require('../scripts/ccr/adapter.cjs');
async function inspect(text, type, split = 7) {
  const observer = responseMetrics(type), chunks = [], bytes = Buffer.from(text), input = [];
  for (let n = 0; n < bytes.length; n += split) input.push(bytes.subarray(n, n + split));
  await pipeline(Readable.from(input), observer.stream, new Writable({ write(chunk, encoding, callback) { chunks.push(chunk); callback(); } }));
  assert.deepEqual(Buffer.concat(chunks), bytes);
  return observer.totals;
}
test('split SSE streams preserve bytes and distinguish cached Anthropic and OpenAI counts', async () => {
  const anthropic = await inspect('event: message_start\r\ndata: {"type":"message_start","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":124360,"cache_creation_input_tokens":87332}}}\r\n\ndata: {"type":"content_block_delta","delta":{"text":"PRIVATE 雪"}}\n\ndata: {"type":"message_delta","usage":{"output_tokens":110}}\n\ndata: {"type":"message_stop"}\n\n', 'text/event-stream');
  assert.equal(anthropic.input_tokens, 211693); assert.equal(anthropic.output_tokens, 110); assert.equal(anthropic.completed, true);
  const openai = await inspect('data: {"type":"response.completed","response":{"usage":{"input_tokens":300000,"input_tokens_details":{"cached_tokens":200000},"output_tokens":20}}}\n\n', 'text/event-stream');
  assert.equal(openai.input_tokens, 300000); assert.equal(openai.cached_input_tokens, 200000);
  assert.doesNotMatch(JSON.stringify(anthropic), /PRIVATE|雪/);
});
test('oversized frames do not retain content or lose the next usage event', async () => {
  const result = await inspect('data: ' + 'x'.repeat(140000) + '\n\ndata: {"type":"message_stop"}\n\n', 'text/event-stream', 4096);
  assert.equal(result.telemetry_truncated, true); assert.equal(result.completed, true);
  assert.equal(result.input_tokens, null);
  const json = await inspect('{"usage":{"input_tokens":10,"output_tokens":2}}', 'application/json');
  assert.equal(json.input_tokens, 10); assert.equal(json.completed, true);
  const partial = await inspect('data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}\n\n', 'text/event-stream');
  assert.equal(partial.completed, false);
  assert.equal((await inspect('{broken', 'application/json')).completed, false);
  assert.equal((await inspect('{"error":{"message":"private"}}', 'application/json')).completed, false);
});
test('provider request IDs are bounded identifiers, not arbitrary header text', () => {
  assert.equal(providerRequestId(new Headers({ 'request-id': 'req_123' })), 'req_123');
  assert.equal(providerRequestId(new Headers({ 'x-request-id': 'private=secret' })), null);
});

test('a priced request reports its cost and an unpriced one reports null, not zero', () => {
  const glm = { input_per_mtok: 0.91, output_per_mtok: 2.86 };
  const charged = metrics.requestCost(glm, { input_tokens: 1000000, output_tokens: 10000 });
  assert.equal(charged, 0.9386, 'full-rate input plus output');
  const cached = metrics.requestCost({ ...glm, cached_input_per_mtok: 0.09 },
    { input_tokens: 1000000, cached_input_tokens: 900000, output_tokens: 10000 });
  assert.equal(cached, 0.2006, 'cached input at its own rate');
  assert.equal(metrics.requestCost({ ...glm, cached_input_per_mtok: 0.09 },
    { input_tokens: 1000000, cached_input_tokens: 2000000, output_tokens: 10000 }), 0.1186,
    'a cached count above input clamps to all input at the cache rate, never negative input');
  assert.equal(metrics.requestCost(undefined, { input_tokens: 10, output_tokens: 10 }), null,
    'no pricing means unknown, never free');
  assert.equal(metrics.requestCost(glm, {}), null, 'missing token counts mean unknown');
  assert.equal(metrics.requestCost({ input_per_mtok: 0.91 }, { input_tokens: 10, output_tokens: 10 }), null,
    'half a price is no price');
});

test('model pricing requires both sides and records the cache rate only with them', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-price-'));
  const prior = process.env.DEX_ROUTER_HOME; process.env.DEX_ROUTER_HOME = dir;
  t.after(() => { if (prior === undefined) delete process.env.DEX_ROUTER_HOME; else process.env.DEX_ROUTER_HOME = prior; fs.rmSync(dir, { recursive: true, force: true }); });
  t.mock.method(adapter, 'health', async () => null);
  const both = await cli.modelCommand('add', ['openrouter/glm-5.3'],
    cli.parse(['--context', '1048576', '--tools', '--upstream', 'z-ai/glm-5.3', '--price-in', '0.91', '--price-out', '2.86', '--price-cached', '0.09']));
  assert.deepEqual(both.pricing, { input_per_mtok: 0.91, output_per_mtok: 2.86, cached_input_per_mtok: 0.09 });
  const bare = await cli.modelCommand('add', ['openrouter/qwen3.8-max-0902'],
    cli.parse(['--context', '1000000', '--tools', '--upstream', 'qwen/qwen3.8-max-0902']));
  assert.equal('pricing' in bare, false, 'a model added without prices carries none');
  await assert.rejects(cli.modelCommand('add', ['openrouter/glm-5.3'],
    cli.parse(['--context', '1048576', '--tools', '--price-in', '0.91'])), /both sides/);
  await assert.rejects(cli.modelCommand('add', ['openrouter/glm-5.3'],
    cli.parse(['--context', '1048576', '--tools', '--price-cached', '0.09'])), /needs --price-in/);
  await assert.rejects(cli.modelCommand('add', ['openrouter/glm-5.3'],
    cli.parse(['--context', '1048576', '--tools', '--price-in', '0.91', '--price-out', 'not-a-number'])), /rate in USD/);
});
