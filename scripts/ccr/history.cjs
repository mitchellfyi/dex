'use strict';

const OPENAI_REASONING = 'ccr-openai-responses-reasoning-v1:';
const ANTHROPIC_REASONING = 'dex-anthropic-messages-reasoning-v1:';
const { StringDecoder } = require('node:string_decoder');

function encodeAnthropic(blocks) {
  return ANTHROPIC_REASONING + Buffer.from(JSON.stringify(blocks)).toString('base64url');
}

function decodeAnthropic(data) {
  if (typeof data !== 'string' || !data.startsWith(ANTHROPIC_REASONING)) return null;
  const blocks = JSON.parse(Buffer.from(data.slice(ANTHROPIC_REASONING.length), 'base64url').toString('utf8'));
  if (!Array.isArray(blocks) || !blocks.every(block => block && (
    (block.type === 'thinking' && typeof block.thinking === 'string' && typeof block.signature === 'string')
    || (block.type === 'redacted_thinking' && typeof block.data === 'string')
    || (block.type === 'text' && typeof block.text === 'string')))) throw new Error('Invalid Claude reasoning history.');
  return blocks;
}

function anthropicBlocks(item) {
  const encoded = decodeAnthropic(item.encrypted_content);
  if (encoded) return encoded;
  if (!Array.isArray(item.reasoning_details)) return null;
  const blocks = item.reasoning_details.flatMap(detail => {
    if (detail.type === 'thinking') return detail.signature ? [detail] : [{ type: 'text', text: detail.thinking || '' }];
    if (detail.type === 'redacted_thinking') return [detail];
    if (detail.format !== 'anthropic-claude-v1') return [];
    if (detail.type === 'reasoning.encrypted') return [{ type: 'redacted_thinking', data: detail.data }];
    if (detail.type === 'reasoning.text') return detail.signature
      ? [{ type: 'thinking', thinking: detail.text || '', signature: detail.signature }]
      : [{ type: 'text', text: detail.text || '' }];
    return [];
  });
  return blocks.length ? blocks : null;
}

function readableReasoning(item) {
  return [...(item.summary || []), ...(item.content || [])]
    .filter(part => ['summary_text', 'reasoning_text'].includes(part.type) && typeof part.text === 'string')
    .map(part => part.text).join('\n');
}

// Only the outgoing copy changes. Opaque reasoning stays in the client's
// history so it can be sent back to the provider that issued it.
function prepareHistory(body, provider, protocol) {
  if (protocol === 'messages' && Array.isArray(body.messages)) {
    body.messages = body.messages.flatMap(message => {
      if (message.role !== 'assistant' || !Array.isArray(message.content)) return [message];
      const content = message.content.flatMap(block => {
        if (block.type === 'redacted_thinking' && typeof block.data === 'string') {
          const openai = block.data.startsWith(OPENAI_REASONING);
          if (openai !== (provider === 'openai')) return [];
        }
        if (provider === 'anthropic' && block.type === 'thinking' && !block.signature) {
          return block.thinking ? [{ type: 'text', text: block.thinking,
            ...(block.cache_control ? { cache_control: block.cache_control } : {}) }] : [];
        }
        if (provider === 'openai' && block.type === 'thinking' && !block.thinking?.trim()) return [];
        return [block];
      });
      return content.length ? [{ ...message, content }] : [];
    });
  }
  if (protocol === 'responses' && Array.isArray(body.input)) {
    body.input = body.input.flatMap(item => {
      if (item.type !== 'reasoning') return [item];
      const blocks = anthropicBlocks(item);
      if (provider === 'anthropic' && blocks) {
        // CCR drops reasoning_details when reading Responses. Carry the signed
        // blocks through encrypted_content and restore them in the provider hook.
        return [{ type: 'reasoning', id: item.id, summary: [], encrypted_content: encodeAnthropic(blocks) }];
      }
      if (provider === 'openai' && !blocks) return [item];
      const text = readableReasoning(item) || blocks?.map(block => block.thinking || block.text || '').filter(Boolean).join('\n');
      return text ? [{ role: 'assistant', content: [{ type: 'output_text', text }] }] : [];
    });
  }
}

function restoreAnthropic(body) {
  if (!Array.isArray(body.messages)) return;
  for (const message of body.messages) {
    if (message.role !== 'assistant' || !Array.isArray(message.content)) continue;
    message.content = message.content.flatMap(block => block.type === 'redacted_thinking'
      ? decodeAnthropic(block.data) || [block] : [block]);
  }
}

function prepareResponseItem(item) {
  if (item?.type !== 'reasoning') return;
  const blocks = anthropicBlocks(item);
  if (!blocks) return;
  const text = readableReasoning(item);
  // Native clients retain encrypted_content, but may discard nonstandard fields.
  item.encrypted_content = encodeAnthropic(blocks);
  item.summary = text ? [{ type: 'summary_text', text }] : [];
  delete item.content; delete item.reasoning_details;
}

function prepareResponseEvent(event) {
  prepareResponseItem(event.item);
  for (const item of event.response?.output || event.output || []) prepareResponseItem(item);
}

async function* prepareResponse(source, contentType) {
  const decoder = new StringDecoder('utf8');
  let pending = '';
  const streaming = contentType?.includes('text/event-stream');
  for await (const chunk of source) {
    pending += decoder.write(Buffer.from(chunk));
    if (streaming) {
      let boundary;
      while ((boundary = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, boundary + 1); pending = pending.slice(boundary + 1);
        if (line.startsWith('data:') && line.slice(5).trim() !== '[DONE]') {
          const event = JSON.parse(line.slice(5)); prepareResponseEvent(event);
          yield `data: ${JSON.stringify(event)}\n`;
        } else yield line;
      }
    }
    if (Buffer.byteLength(pending) > 32 * 1024 * 1024) throw new Error('Claude response exceeded the gateway limit.');
  }
  pending += decoder.end();
  if (streaming) { if (pending) throw new Error('Claude response ended before its final event.'); }
  else { const body = JSON.parse(pending); prepareResponseEvent(body); yield JSON.stringify(body); }
}

module.exports = { prepareHistory, restoreAnthropic, prepareResponse };
