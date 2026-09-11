'use strict';
const ipc = require('./ipc.cjs');

function createGatewayPlugin() {
  return { providerHooks: ['anthropic', 'openai'].map(provider => ({
    key: `dex-${provider}-oauth`, providerName: `dex-${provider}`,
    async authenticate(input) {
      const ticket = input.request?.headers?.['x-ccr-dex-account-ticket'];
      if (typeof ticket !== 'string') return { ok: false, error: 'Dex account authorization is required.' };
      const result = await ipc.call('credential', { ticket, provider });
      const headers = { ...input.upstreamRequest.headers };
      for (const name of Object.keys(headers)) if (['authorization', 'x-api-key', 'x-ccr-dex-account-ticket'].includes(name.toLowerCase())) delete headers[name];
      Object.assign(headers, result.headers);
      if (provider === 'anthropic') {
        headers['anthropic-beta'] = [...new Set(`${input.request?.headers?.['anthropic-beta'] || ''},oauth-2025-04-20`.split(',').filter(Boolean))].join(',');
      }
      let body = input.upstreamRequest.body;
      if (provider === 'openai' && body && typeof body === 'object') {
        body = { ...body, store: false, stream: true, instructions: body.instructions || 'You are an engineering assistant.' };
        for (const key of ['max_output_tokens', 'max_tokens', 'temperature', 'top_p']) delete body[key];
      }
      return { ok: true, value: { ...input.upstreamRequest, headers, body } };
    }
  })) };
}
module.exports = { createGatewayPlugin };
