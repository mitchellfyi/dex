'use strict';
// CCR requires this file once and keeps it for the life of the gateway, so it
// holds no routing logic. It forwards to a RouterService and replaces that
// service when the sources beside it change. Editing this file, or source.cjs,
// still needs dx router restart; keep both small.
const fs = require('node:fs');
const path = require('node:path');
const { sourceRevision, checkSources, gitBusy } = require('./source.cjs');

const SETTLE_MS = 1000;
const FIXED = [__filename, require.resolve('./source.cjs')];

const modulesNow = () => ({ state: require('./state.cjs'), ...require('./service.cjs') });
// Drops every other router module and loads them again. An instance already
// running keeps the module objects it holds, so its requests finish on them.
function load() {
  checkSources();
  for (const key of Object.keys(require.cache)) if (path.dirname(key) === __dirname && !FIXED.includes(key)) delete require.cache[key];
  return modulesNow();
}

function createExtension(options = {}) {
  let modules, service, watcher, reloading = null;
  const status = { source_revision: null, reload_count: 0, last_reload_at: null, last_reload_error: null };
  const instance = loaded => {
    const settings = loaded.state.backend();
    return new loaded.RouterService({ gateway: settings.gateway, clientKey: settings.client_key, ...options });
  };
  const journal = (type, fields) => {
    try { modules.event(null, type, fields); } catch { /* The journal is diagnostics; the reload stands without it. */ }
  };
  function reload() {
    reloading ||= (async () => {
      const source = sourceRevision();
      let loaded, next;
      try { loaded = load(); next = instance(loaded); next.adopt(service); }
      catch (error) {
        // The previous instance never stopped serving, so nothing is rolled back.
        status.last_reload_error = error.message;
        journal('router.reload_failed', { error: error.message });
        return { reloaded: false, ...status };
      }
      const previous = service;
      modules = loaded; service = next;
      Object.assign(status, { source_revision: source, reload_count: status.reload_count + 1, last_reload_at: Date.now(), last_reload_error: null });
      previous.retire();
      journal('router.reloaded', { reload_count: status.reload_count });
      return { reloaded: true, ...status };
    })().finally(() => { reloading = null; });
    return reloading;
  }
  async function dispatch(method, params) {
    if (method === 'reload') return reload();
    const result = await service.control(method, params);
    if (method === 'health') return { ...result, ...status };
    // The core plugin reloads its own helpers when this revision moves, so the
    // two halves of a request never run different code for long.
    if (method === 'credential') return { ...result, source_revision: status.source_revision };
    return result;
  }
  // Reloads once the sources have stopped changing for a whole interval and no
  // git operation is rewriting them, so a save in progress or a checkout
  // midway is not what gets loaded.
  function watch() {
    if (process.env.DEX_ROUTER_HOT_RELOAD === '0') return null;
    let timer = null, pending = null;
    const arm = () => { clearTimeout(timer); timer = setTimeout(settle, SETTLE_MS); timer.unref(); };
    function settle() {
      timer = null;
      const revision = sourceRevision();
      if (revision === status.source_revision) return;
      if (revision !== pending || gitBusy()) { pending = revision; arm(); return; }
      reload().catch(() => {});
    }
    const handle = fs.watch(__dirname, (_type, name) => { if (!name || name.endsWith('.cjs')) arm(); });
    // Losing the watch only loses automatic reloads; dx router reload still works.
    handle.on('error', () => handle.close());
    handle.unref();
    return { close: () => { clearTimeout(timer); handle.close(); } };
  }
  return {
    async setup(ctx) {
      status.source_revision = sourceRevision();
      modules = modulesNow();
      service = instance(modules);
      await service.start({ dispatch });
      watcher = watch();
      ctx.registerGatewayRoute({ id: 'dex-subscription-session', pathPrefix: '/plugins/dex/', auth: 'none', handler: (request, response) => service.handle(request, response) });
      ctx.registerCoreGatewayPlugin({ key: 'dex-subscription-auth', enabled: true, modulePath: path.join(__dirname, 'core-plugin.cjs') });
      ctx.registerProviderAccountConnector({ id: 'dex-subscription-usage', resolve: async request => {
        const provider = request.provider.name.replace(/^dex-/, '');
        await service.control('usage', {});
        return modules.state.accounts().filter(item => item.provider === provider).flatMap(account => (account.usage?.windows || []).map(window => ({
          id: `${account.id}-${window.name}`, label: `${account.name}: ${window.name}`, kind: 'quota', unit: '%', limit: 100,
          used: (1 - window.remaining_ratio) * 100, remaining: window.remaining_ratio * 100,
          resetAt: window.resets_at ? new Date(window.resets_at).toISOString() : undefined
        })));
      } });
      return { stop: () => { watcher?.close(); return service.stop(); } };
    },
    reload
  };
}
module.exports = { ...createExtension(), createExtension };
