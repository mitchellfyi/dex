'use strict';
const path = require('node:path');
const state = require('./state.cjs');
const { RouterService } = require('./service.cjs');

function createExtension(options = {}) { return {
  async setup(ctx) {
    const settings = state.read(state.stateFile('backend'));
    const service = new RouterService({ gateway: settings.gateway, clientKey: settings.client_key, ...options });
    await service.start();
    ctx.registerGatewayRoute({ id: 'dex-subscription-session', pathPrefix: '/plugins/dex/', auth: 'none', handler: (request, response) => service.handle(request, response) });
    ctx.registerCoreGatewayPlugin({ key: 'dex-subscription-auth', enabled: true, modulePath: path.join(__dirname, 'core-plugin.cjs') });
    ctx.registerProviderAccountConnector({ id: 'dex-subscription-usage', resolve: async request => {
      const provider = request.provider.name.replace(/^dex-/, '');
      await service.control('usage', {});
      return state.accounts().filter(item => item.provider === provider).flatMap(account => (account.usage?.windows || []).map(window => ({
        id: `${account.id}-${window.name}`, label: `${account.name}: ${window.name}`, kind: 'quota', unit: '%', limit: 100,
        used: (1 - window.remaining_ratio) * 100, remaining: window.remaining_ratio * 100,
        resetAt: window.resets_at ? new Date(window.resets_at).toISOString() : undefined
      })));
    } });
    return { stop: () => service.stop() };
  }
}; }
module.exports = { ...createExtension(), createExtension };
