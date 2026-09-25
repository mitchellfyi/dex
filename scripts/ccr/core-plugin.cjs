'use strict';
const path = require('node:path');
const ipc = require('./ipc.cjs');
const { PROVIDER_ENDPOINTS } = require('./policy.cjs');

// CCR loads this module once, possibly outside the extension's module
// registry. When the extension reports that it reloaded, load the helpers
// again from the same sources; keep the working copies if that fails.
const helpers = { revision: undefined, history: require('./history.cjs'), policy: require('./policy.cjs') };
function follow(revision) {
  if (revision === undefined || revision === helpers.revision) return;
  try {
    for (const key of Object.keys(require.cache)) if (path.dirname(key) === __dirname && ![__filename, require.resolve('./ipc.cjs')].includes(key)) delete require.cache[key];
    Object.assign(helpers, { revision, history: require('./history.cjs'), policy: require('./policy.cjs') });
  } catch { /* The next credential call retries. */ }
}

const CLAUDE_SUBSCRIPTION_PRELUDE = "You are Claude Code, Anthropic's official CLI for Claude.";

function convertedReasoning(item) {
  if (item.type !== 'reasoning' || item.encrypted_content || !Array.isArray(item.content) || !item.content.length
    || !item.content.every(part => part.type === 'reasoning_text' && typeof part.text === 'string')) return item;
  // CCR gives Claude thinking a generated OpenAI item ID and raw content.
  // Stateless Responses accepts the text as summaries, without that unknown ID.
  const { id, content, ...reasoning } = item;
  return { ...reasoning, summary: [...(item.summary || []), ...content.map(part => ({ type: 'summary_text', text: part.text }))] };
}

function createGatewayPlugin() {
  return { providerHooks: Object.keys(PROVIDER_ENDPOINTS).map(provider => ({
    key: `dex-${provider}-oauth`, providerName: `dex-${provider}`,
    async authenticate(input) {
      const ticket = input.request?.headers?.['x-ccr-dex-account-ticket'];
      if (typeof ticket !== 'string') return { ok: false, error: 'Dex account authorization is required.' };
      const result = await ipc.call('credential', { ticket, provider });
      follow(result.source_revision);
      const { restoreAnthropic } = helpers.history, { chatReasoning } = helpers.policy;
      const headers = { ...input.upstreamRequest.headers };
      for (const name of Object.keys(headers)) if (['authorization', 'x-api-key', 'x-ccr-dex-account-ticket'].includes(name.toLowerCase())) delete headers[name];
      Object.assign(headers, result.headers);
      if (provider === 'anthropic') {
        const betas = `${input.request?.headers?.['anthropic-beta'] || ''},oauth-2025-04-20`.split(',').map(beta => beta.trim()).filter(Boolean);
        if (input.sourceAdapterKey === 'openai_responses') betas.push('claude-code-20250219');
        headers['anthropic-beta'] = [...new Set(betas)].join(',');
      }
      let body = input.upstreamRequest.body;
      if (provider === 'anthropic' && body && typeof body === 'object') {
        restoreAnthropic(body);
        if (input.sourceAdapterKey === 'openai_responses') {
          // The subscription endpoint requires this prelude even after protocol
          // conversion. Keep the original client instructions after it.
          const system = typeof body.system === 'string' ? [{ type: 'text', text: body.system }] : body.system ?? [];
          if (!Array.isArray(system)) return { ok: false, error: 'Invalid Anthropic system content after Responses conversion.' };
          if (!system[0]?.text?.startsWith(CLAUDE_SUBSCRIPTION_PRELUDE)) {
            body = { ...body, system: [{ type: 'text', text: CLAUDE_SUBSCRIPTION_PRELUDE }, ...system] };
          }
        }
        const effort = input.sourceAdapterKey === 'openai_responses' && input.request?.body?.reasoning?.effort;
        if (effort) body = { ...body, output_config: { ...body.output_config, effort } };
      }
      if (provider === 'openai' && body && typeof body === 'object') {
        body = { ...body, store: false, stream: true, instructions: body.instructions || 'You are an engineering assistant.' };
        for (const key of ['max_output_tokens', 'max_tokens', 'temperature', 'top_p']) delete body[key];
        if (input.sourceAdapterKey === 'anthropic_messages' && Array.isArray(body.input)) body.input = body.input.map(convertedReasoning);
      }
      if (PROVIDER_ENDPOINTS[provider].type === 'openai_chat_completions' && body && typeof body === 'object') {
        const effort = chatReasoning(input.request?.body);
        if (effort) body = { ...body, reasoning: { ...body.reasoning, effort } };
      }
      return { ok: true, value: { ...input.upstreamRequest, headers, body } };
    },
    transformResponse(input) {
      return { ok: true, value: provider === 'anthropic' && input.sourceAdapterKey === 'openai_responses'
        ? helpers.history.wrapAnthropicResponse(input.upstreamPayload) : input.upstreamPayload };
    }
  })) };
}
module.exports = { createGatewayPlugin };
