'use strict';
// Codex asks its provider for GET /models and expects its own catalogue shape,
// { models: [ModelInfo] }. Without an entry for dex/active it runs on fallback
// metadata: no apply_patch tool, no skills or plugin instructions, generic base
// instructions, no reasoning levels and byte-based tool output truncation. The
// alias mirrors the OpenAI model the route serves, read from the same upstream
// catalogue as dx model discover, so Codex keeps its native tooling.
const { authHeaders } = require('./accounts.cjs');
const policy = require('./policy.cjs');

const ALIAS = 'dex/active';
const CATALOGUE = 'https://chatgpt.com/backend-api/codex/models';
const CACHE_TTL = 10 * 60 * 1000;
const VERSION = /^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/;

// GPT-5 family defaults from the Codex catalogue, used when the route has no
// OpenAI model or its metadata cannot be read.
function template(context) {
  const levels = { low: 'Fast responses with lighter reasoning.', medium: 'Balanced speed and reasoning.', high: 'Deeper reasoning for complex work.', xhigh: 'Maximum reasoning for the hardest problems.' };
  return {
    slug: ALIAS, display_name: ALIAS, description: null,
    default_reasoning_level: 'medium', supported_reasoning_levels: Object.entries(levels).map(([effort, description]) => ({ effort, description })),
    shell_type: 'unified_exec', visibility: 'list', supported_in_api: true, priority: 0, availability_nux: null, upgrade: null,
    support_verbosity: true, default_verbosity: 'low', apply_patch_tool_type: 'freeform', web_search_tool_type: 'text_and_image',
    input_modalities: ['text', 'image'], supports_image_detail_original: true, truncation_policy: { mode: 'tokens', limit: 10000 },
    supports_parallel_tool_calls: true, include_skills_usage_instructions: true, include_plugin_usage_instructions: true, include_apps_usage_instructions: true,
    supports_reasoning_summary_parameter: true, default_reasoning_summary: 'none', supports_search_tool: true,
    context_window: context, max_context_window: context, auto_compact_token_limit: null, experimental_supported_tools: []
  };
}

function alias(entry, context) {
  return { ...entry, slug: ALIAS, display_name: 'Dex automatic route', description: 'Follows the Dex route and its fallbacks.',
    visibility: 'list', priority: 0, supported_in_api: true, availability_nux: null, upgrade: null,
    context_window: context, max_context_window: context };
}

class CodexCatalog {
  constructor({ broker, fetchImpl = fetch } = {}) { this.broker = broker; this.fetch = fetchImpl; this.cache = new Map(); }
  // The upstream catalogue is filtered by client version; Codex sends its own.
  async upstream(account, version) {
    const key = `${account.id}:${version}`;
    const cached = this.cache.get(key);
    if (cached && cached.expires > Date.now()) return cached.models;
    let models = [];
    try {
      const credentials = await this.broker.access(account);
      const response = await this.fetch(`${CATALOGUE}?client_version=${encodeURIComponent(version)}`, { headers: authHeaders('openai', credentials), redirect: 'error', signal: AbortSignal.timeout(15000) });
      const payload = response.ok ? await response.json() : null;
      if (Array.isArray(payload?.models)) models = payload.models.filter(item => typeof item?.slug === 'string');
    } catch { /* Codex works on the template until the catalogue is reachable. */ }
    if (models.length) this.cache.set(key, { models, expires: Date.now() + CACHE_TTL });
    return models;
  }
  async models({ session, selected, accounts, version }) {
    const context = session.context_limit;
    const target = selected.models.find(item => item.provider === 'openai');
    let upstream = [];
    if (target && VERSION.test(version || '')) {
      const account = policy.candidates(accounts, { models: [target], pinned: selected.pinned }, session, Date.now(), 'responses')[0]?.account;
      if (account) upstream = await this.upstream(account, version);
    }
    const match = target && upstream.find(item => item.slug === (target.upstream_id || target.id.split('/')[1]));
    return { models: [alias(match || template(context), context), ...upstream.filter(item => item.slug !== ALIAS)] };
  }
}

module.exports = { ALIAS, CodexCatalog, template, alias };
