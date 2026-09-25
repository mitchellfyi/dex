'use strict';
// Everything the gateway runs for Dex, behind the extension.cjs shim. A reload
// loads this file again along with the rest, so the reload logic itself can
// change without restarting the gateway.
const fs = require('node:fs');
const path = require('node:path');
const { sourceRevision, checkSources, gitBusy } = require('./source.cjs');

const SETTLE_MS = 1000;
const SHIM = path.join(__dirname, 'extension.cjs');

function journal(generation, type, fields) {
  try { generation.modules.event(null, type, fields); } catch { /* The journal is diagnostics; the reload stands without it. */ }
}

// Loads a fresh copy of every router module except the shim, then builds and
// activates a generation from it. The generation it replaces keeps the module
// objects it holds, so requests it already accepted finish on that code.
function reload(live) {
  live.reloading ||= (async () => {
    const previous = live.generation;
    const revision = sourceRevision();
    try {
      checkSources();
      for (const key of Object.keys(require.cache)) if (path.dirname(key) === __dirname && key !== SHIM) delete require.cache[key];
      await require('./host.cjs').install(live, previous, revision);
      return { reloaded: true, ...live.generation.status };
    } catch (error) {
      // The previous generation never stopped serving, so nothing is rolled back.
      previous.status.last_reload_error = error.message;
      journal(previous, 'router.reload_failed', { error: error.message });
      return { reloaded: false, ...previous.status };
    }
  })().finally(() => { live.reloading = null; });
  return live.reloading;
}

// Reloads once the sources have stopped changing for a whole interval and no
// git operation is rewriting them, so a save in progress or a checkout
// midway is not what gets loaded.
function watch(live) {
  if (process.env.DEX_ROUTER_HOT_RELOAD === '0') return null;
  let timer = null, pending = null;
  const arm = () => { clearTimeout(timer); timer = setTimeout(settle, SETTLE_MS); timer.unref(); };
  function settle() {
    timer = null;
    const revision = sourceRevision();
    if (revision === live.generation.status.source_revision) return;
    if (revision !== pending || gitBusy()) { pending = revision; arm(); return; }
    live.reload().catch(() => {});
  }
  let handle;
  // Losing the watch only loses automatic reloads; dx router reload still works.
  try { handle = fs.watch(__dirname, (_type, name) => { if (!name || name.endsWith('.cjs')) arm(); }); } catch { return null; }
  handle.on('error', () => handle.close());
  handle.unref();
  return { close: () => { clearTimeout(timer); handle.close(); } };
}

function shimChanged(live) {
  try { return fs.statSync(SHIM).mtimeMs > live.loadedAt; } catch { return false; }
}

async function dispatch(live, generation, method, params) {
  if (method === 'reload') return live.reload();
  const result = await generation.service.control(method, params);
  if (method === 'health') return { ...result, ...generation.status, shim_changed: shimChanged(live) };
  // The core plugin reloads its own helpers when this revision moves, so the
  // two halves of a request never run different code for long.
  if (method === 'credential') return { ...result, source_revision: generation.status.source_revision };
  return result;
}

async function usage(generation, request) {
  const provider = request.provider.name.replace(/^dex-/, '');
  await generation.service.control('usage', {});
  return generation.modules.state.accounts().filter(item => item.provider === provider).flatMap(account => (account.usage?.windows || []).map(window => ({
    id: `${account.id}-${window.name}`, label: `${account.name}: ${window.name}`, kind: 'quota', unit: '%', limit: 100,
    used: (1 - window.remaining_ratio) * 100, remaining: window.remaining_ratio * 100,
    resetAt: window.resets_at ? new Date(window.resets_at).toISOString() : undefined
  })));
}

// Builds a generation from this copy of the modules and points the shim's
// forwarding functions at it. previous is the generation being replaced, or
// null when the gateway starts. Everything that can fail runs before the swap.
async function install(live, previous, revision = sourceRevision()) {
  const modules = { state: require('./state.cjs'), ...require('./service.cjs') };
  const settings = modules.state.backend();
  const service = new modules.RouterService({ gateway: settings.gateway, clientKey: settings.client_key, ...live.options });
  const status = previous
    ? { ...previous.status, source_revision: revision, reload_count: previous.status.reload_count + 1, last_reload_at: Date.now(), last_reload_error: null }
    : { source_revision: revision, reload_count: 0, last_reload_at: null, last_reload_error: null };
  const generation = { service, status, modules, watcher: null };
  if (previous) service.adopt(previous.service);
  Object.assign(live, {
    generation,
    handle: (request, response) => service.handle(request, response),
    dispatch: (method, params) => dispatch(live, generation, method, params),
    usage: request => usage(generation, request),
    reload: () => reload(live),
    stop: async () => { generation.watcher?.close(); await service.stop(); }
  });
  // The socket dispatches through the shim, so whichever generation is live answers.
  if (!previous) await service.start({ dispatch: (method, params) => live.dispatch(method, params) });
  if (previous) {
    previous.watcher?.close();
    previous.service.retire();
    journal(generation, 'router.reloaded', { reload_count: status.reload_count });
  }
  generation.watcher = watch(live);
}

module.exports = { install };
