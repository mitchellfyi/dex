'use strict';
// CCR requires this file once and keeps it for the life of the gateway. It
// holds only the references CCR keeps and forwards each one to host.cjs, which
// replaces itself and the router service when the sources change. This file is
// the one part a reload cannot replace: editing it needs dx router restart.
const path = require('node:path');

function createExtension(options = {}) {
  const live = { options, loadedAt: Date.now() };
  return {
    async setup(ctx) {
      await require('./host.cjs').install(live, null);
      ctx.registerGatewayRoute({ id: 'dex-subscription-session', pathPrefix: '/plugins/dex/', auth: 'none', handler: (request, response) => live.handle(request, response) });
      ctx.registerCoreGatewayPlugin({ key: 'dex-subscription-auth', enabled: true, modulePath: path.join(__dirname, 'core-plugin.cjs') });
      ctx.registerProviderAccountConnector({ id: 'dex-subscription-usage', resolve: request => live.usage(request) });
      return { stop: () => live.stop() };
    },
    reload: () => live.reload()
  };
}
module.exports = { ...createExtension(), createExtension };
