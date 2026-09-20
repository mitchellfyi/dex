'use strict';

// Claude Code resolves a model's context window locally, before any request.
// A routed launch points at the local gateway, so it is never first-party: a
// name the client recognises resolves to that model's believed 200k window,
// and CLAUDE_CODE_MAX_CONTEXT_TOKENS is ignored for it. The [1m] name marker
// is the client's own supported way to ask for the 1M window, and it applies
// to recognised and routed names alike. Compaction then follows the client's
// own policy against CLAUDE_CODE_AUTO_COMPACT_WINDOW, which it clamps to that
// window, so Dex states the route's real budget and imposes no schedule of
// its own.
const LONG_CONTEXT_MARKER = '[1m]';

// Anthropic still gates 1M input on this beta upstream, and the gateway only
// forwards it on Anthropic requests. It governs the provider request, not the
// client's local window arithmetic.
const LONG_CONTEXT_BETA = 'context-1m-2025-08-07';

// Preserves any betas the user already asked for instead of replacing them.
function betaHeader(requested) {
  const existing = (requested || '').split(',').map(value => value.trim()).filter(Boolean);
  return [...new Set([...existing, LONG_CONTEXT_BETA])].join(',');
}

// Claude Code appends the marker itself when it resolves an alias, so a value
// coming back from the client can carry more than one.
function plainModel(id) { return String(id).replace(/(\[1m\])+$/i, ''); }
function longContext(id) { return `${plainModel(id)}${LONG_CONTEXT_MARKER}`; }

// A native client starts on the first model of its own route, because running
// that client directly is a request for that client's models. dex/active stays
// in the picker one keystroke away, and a Dex lifecycle names it explicitly,
// so neither choice depends on what the other client is configured to do.
function clientDefault(config, client) {
  return (client && config.client_routes?.[client]?.model) || 'dex/active';
}

function claudePicker(config, client) {
  const clientRoute = client && config.client_routes?.[client];
  const routes = clientRoute ? [clientRoute] : Object.values(config.phases || {});
  const ids = new Set([...(clientRoute ? [] : [config.default_model]), ...routes.flatMap(route => [route.model, ...(route.fallbacks || [])])]);
  return {
    replaceBuiltInOptions: true,
    options: [
      { model: longContext('dex/active'), label: 'CCR subscription', description: 'Automatic Dex route, account pool, and fallbacks.' },
      ...[...ids].map(id => config.models.find(model => model.id === id)).filter(Boolean).map(model => ({
        model: longContext(model.id),
        label: `${model.display_name || model.id} (via CCR)`,
        description: 'Use this model through the Dex account pool. This does not bypass the router.'
      }))
    ]
  };
}

module.exports = { claudePicker, clientDefault, betaHeader, plainModel, longContext, LONG_CONTEXT_BETA, LONG_CONTEXT_MARKER };
