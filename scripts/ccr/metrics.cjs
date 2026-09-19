'use strict';
const { Transform } = require('node:stream');
const { StringDecoder } = require('node:string_decoder');

function responseMetrics(contentType) {
  const totals = { input_tokens: null, cached_input_tokens: null, output_tokens: null, completed: false, telemetry_truncated: false };
  const decoder = new StringDecoder('utf8');
  const streaming = /text\/event-stream/i.test(contentType || '');
  let pending = '', skipped = false;
  const number = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
  const observe = record => {
    const usage = record?.message?.usage || record?.response?.usage || record?.usage;
    if (usage) {
      const input = number(usage.input_tokens);
      const cached = number(usage.cache_read_input_tokens) ?? number(usage.input_tokens_details?.cached_tokens);
      if (input !== null) totals.input_tokens = input + (number(usage.cache_read_input_tokens) ?? 0) + (number(usage.cache_creation_input_tokens) ?? 0);
      if (cached !== null) totals.cached_input_tokens = cached;
      if (number(usage.output_tokens) !== null) totals.output_tokens = usage.output_tokens;
    }
    if (record?.type === 'message_stop' || record?.type === 'response.completed') totals.completed = true;
  };
  const parse = text => { try { const value = JSON.parse(text); observe(value); return value; } catch { return null; } };
  const consume = text => {
    if (!streaming) {
      if (!skipped) pending += text;
      if (pending.length > 128 * 1024) { pending = ''; skipped = true; totals.telemetry_truncated = true; }
      return;
    }
    const lines = text.split('\n');
    for (let index = 0; index < lines.length; index++) {
      if (!skipped) pending += lines[index];
      if (pending.length > 128 * 1024) { pending = ''; skipped = true; totals.telemetry_truncated = true; }
      if (index < lines.length - 1) {
        if (!skipped && pending.startsWith('data:')) parse(pending.slice(5).trim());
        pending = ''; skipped = false;
      }
    }
  };
  const stream = new Transform({
    transform(chunk, encoding, callback) { consume(decoder.write(chunk)); callback(null, chunk); },
    flush(callback) {
      consume(decoder.end());
      if (!streaming && !skipped) {
        const value = parse(pending);
        totals.completed = Boolean(value && typeof value === 'object' && !Array.isArray(value) && !value.error && value.status !== 'failed');
      }
      else if (streaming && pending.startsWith('data:')) parse(pending.slice(5).trim());
      callback();
    }
  });
  return { stream, totals };
}

function providerRequestId(headers) {
  const value = headers.get('request-id') || headers.get('x-request-id');
  return typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,160}$/.test(value) ? value : null;
}
module.exports = { responseMetrics, providerRequestId };
