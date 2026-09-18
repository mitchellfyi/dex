'use strict';

function claudePicker(config, client) {
  const clientRoute = client && config.client_routes?.[client];
  const routes = clientRoute ? [clientRoute] : Object.values(config.phases || {});
  const ids = new Set([...(clientRoute ? [] : [config.default_model]), ...routes.flatMap(route => [route.model, ...(route.fallbacks || [])])]);
  return {
    replaceBuiltInOptions: true,
    options: [
      { model: 'dex/active', label: 'CCR subscription', description: 'Automatic Dex route, account pool, and fallbacks.' },
      ...[...ids].map(id => config.models.find(model => model.id === id)).filter(Boolean).map(model => ({
        model: model.id,
        label: `${model.display_name || model.id} (via CCR)`,
        description: 'Use this model through the Dex account pool. This does not bypass the router.'
      }))
    ]
  };
}

module.exports = { claudePicker };
