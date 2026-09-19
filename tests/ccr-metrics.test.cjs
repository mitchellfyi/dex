'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Readable, Writable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { responseMetrics, providerRequestId } = require('../scripts/ccr/metrics.cjs');
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
