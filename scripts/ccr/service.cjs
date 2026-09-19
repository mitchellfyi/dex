'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const state = require('./state.cjs');
const policy = require('./policy.cjs');
const { prepareHistory, prepareResponse } = require('./history.cjs');
const ipc = require('./ipc.cjs');
const { AccountBroker, authHeaders } = require('./accounts.cjs');
const { CodexCatalog } = require('./codex-catalog.cjs');
const { responseMetrics, requestCost, providerRequestId } = require('./metrics.cjs');

// Failover events keep the provider's own explanation (a quota window versus a
// rejected converted request) as a short cleaned excerpt; bodies never land in
// the journal.
function providerError(payload) {
  const error = payload?.error;
  if (!error || typeof error !== 'object') return null;
  const clean = value => typeof value === 'string' ? value.replace(/[\x00-\x1f\x7f-\x9f]/g, ' ').slice(0, 200) : null;
  return { type: clean(error.type), message: clean(error.message) };
}

function upstreamError(payload, status) {
  const attempts = payload?.error?.attempts;
  if (Array.isArray(attempts) && attempts.length === 1 && attempts[0]?.status === status) {
    return upstreamError(attempts[0]?.details, status);
  }
  return payload?.error || payload?.response?.error
    || (typeof payload?.detail === 'string' ? { message: payload.detail } : payload?.detail);
}

function contextError(payload, status) {
  const error = upstreamError(payload, status);
  if (error?.code === 'context_length_exceeded') return true;
  return typeof error?.message === 'string' && /^(?:prompt is too long\b|your input exceeds the context window\b|this model's maximum context length is\b)/i.test(error.message);
}

function termsAcceptanceRequired(payload, status, provider) {
  if (provider !== 'anthropic' || ![400, 403].includes(status)) return false;
  const error = upstreamError(payload, status);
  return typeof error?.message === 'string'
    && /^We['’]ve updated our Consumer Terms and Privacy Policy\. You['’]ll need to accept them in claude\.ai\b/i.test(error.message);
}

function rejectionDetails(payload, status) {
  const error = upstreamError(payload, status);
  const identifier = value => typeof value === 'string' && /^[A-Za-z_][A-Za-z0-9_.-]{0,99}$/.test(value) ? value : null;
  return {
    type: identifier(error?.type), code: identifier(error?.code),
    param: typeof error?.param === 'string' && /^[A-Za-z_][A-Za-z0-9_.\[\]]{0,159}$/.test(error.param) ? error.param : null
  };
}

function processIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return '';
  const result = spawnSync('bash', [path.resolve(__dirname, '../../bin/router-runtime.sh'), 'identity', String(pid)], { encoding: 'utf8', timeout: 3000, env: { ...process.env, DEX_DIR: path.resolve(__dirname, '../..') } });
  return result.status === 0 ? result.stdout.trim() : '';
}
function active(session) { return session.active === true && Boolean(session.owner_identity) && processIdentity(session.owner_pid) === session.owner_identity; }
function publicSession(session) {
  const { auth_hash, phase_file, journal, owner_identity, ...safe } = session;
  return { ...safe, active: active(session) };
}
function event(session, type, fields) {
  const row = { version: 1, type, run_id: session?.run_id || null, session_id: session?.id || null, timestamp: new Date().toISOString(), data: fields };
  const file = path.join(state.root(), 'events.jsonl');
  state.privateDir(state.root());
  const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
  try {
    const metadata = fs.fstatSync(fd);
    if (!metadata.isFile() || metadata.uid !== process.getuid() || (metadata.mode & 0o077)) throw new Error('Unsafe routing event journal.');
    fs.writeSync(fd, `${JSON.stringify(row)}\n`);
  } finally { fs.closeSync(fd); }
  if (session?.run_id) {
    const child = spawn('bash', [path.resolve(__dirname, '../../bin/router-runtime.sh'), 'event', session.run_id, type, String(fields.phase ?? session.phase ?? ''), JSON.stringify({ router_session_id: session.id, ...fields })], {
      stdio: 'ignore', timeout: 10000, env: { ...process.env, DEX_DIR: path.resolve(__dirname, '../..'), ...(session.run_root ? { DX_RUN_ROOT: session.run_root } : {}) }
    });
    child.on('error', () => {});
  }
  return row;
}

class RouterService {
  constructor({ gateway, clientKey, broker = new AccountBroker(), fetchImpl = fetch } = {}) {
    this.gateway = gateway; this.clientKey = clientKey; this.broker = broker; this.fetch = fetchImpl;
    this.tickets = new Map(); this.inFlight = new Set(); this.server = null;
    this.metricWrites = new Set(); this.telemetryFailures = 0;
    this.ownerIdentity = processIdentity(process.pid);
    // Delegate lazily: tests and recovery swap the broker and fetch after construction.
    this.codexCatalog = new CodexCatalog({ broker: { access: (...args) => this.broker.access(...args) }, fetchImpl: (...args) => this.fetch(...args) });
  }
  async start() {
    const socket = ipc.socketPath();
    if (fs.existsSync(socket)) {
      try { await ipc.call('health', {}, 500); throw new Error('A Dex router is already running.'); }
      catch (error) { if (!/not running/.test(error.message)) throw error; fs.unlinkSync(socket); }
    }
    this.server = http.createServer(async (request, response) => {
      try {
        if (request.method !== 'POST' || request.url !== '/dex/v1') { ipc.json(response, 404, { error: 'Unknown local endpoint.' }); return; }
        const payload = await ipc.body(request);
        if (payload.version !== 1) throw new Error('Unsupported extension interface version.');
        ipc.json(response, 200, await this.control(payload.method, payload.params || {}));
      } catch (error) { ipc.json(response, 400, { error: error.message }); }
    });
    await new Promise((resolve, reject) => { this.server.once('error', reject); this.server.listen(socket, resolve); });
    fs.chmodSync(socket, 0o600);
    this.timer = setInterval(() => { for (const [key, value] of this.tickets) if (value.expires < Date.now()) this.tickets.delete(key); }, 30000);
    this.timer.unref();
    this.quotaTimer = setInterval(() => { this.control('usage', {}).catch(() => {}); }, 60000);
    this.quotaTimer.unref();
  }
  async stop() {
    clearInterval(this.timer);
    clearInterval(this.quotaTimer);
    for (const controller of this.inFlight) controller.abort();
    await Promise.allSettled([...this.metricWrites]);
    this.tickets.clear();
    if (this.server) await new Promise(resolve => this.server.close(resolve));
  }
  async control(method, params) {
    // Routine probes must not wait for process checks on every registered session.
    if (method === 'health') return { version: 1, extension: 'dex-ccr', capabilities: ['messages', 'responses', 'native-auth'], pid: process.pid,
      owner_identity: this.ownerIdentity, active_requests: this.inFlight.size, telemetry_failures: this.telemetryFailures,
      ...(params?.sessions ? { active_sessions: state.sessions().filter(active).length } : {}) };
    if (method === 'sessions') return state.sessions().map(publicSession);
    if (method === 'native-auth') {
      const config = state.config();
      if (!['claude', 'codex'].includes(params.client)) throw new Error('Expected claude or codex.');
      const identity = processIdentity(params.owner_pid);
      if (!identity) throw new Error('The native client is no longer running.');
      const id = `native-${params.client}-${params.owner_pid}`;
      const token = require('node:crypto').createHmac('sha256', this.clientKey).update(`${id}:${identity}`).digest('base64url');
      await state.locked('sessions', () => {
        const saved = state.read(state.sessionFile(id), {});
        if (active(saved) && saved.auth_hash === state.hash(token)) return;
        if (!config.enabled || !config.native?.enabled) throw new Error('Native routing is disabled. Run dx router native enable.');
        const session = { version: 1, id, active: true, owner_pid: params.owner_pid, owner_identity: identity, auth_hash: state.hash(token), client: params.client,
          context_limit: policy.contextLimit(config, params.client) };
        state.write(state.sessionFile(id), session);
        event(session, 'route.session_started', { client: params.client, context_limit: session.context_limit });
      });
      return { token };
    }
    if (method === 'register') return state.locked('sessions', () => {
      if (!state.config().enabled) throw new Error('CCR routing is disabled. Run dx router setup.');
      const id = state.checkedId(params.id);
      const saved = state.read(state.sessionFile(id), {});
      if (active(saved)) throw new Error('This Dex session already has a running routed agent.');
      const old = params.resume === false ? {} : saved;
      if (params.run_id && (!/^run_[A-Za-z0-9._-]{1,196}$/.test(params.run_id) || params.run_id.includes('..'))) throw new Error('Invalid Dex run ID.');
      if (typeof params.token !== 'string' || params.token.length < 32 || !processIdentity(params.owner_pid)) throw new Error('Invalid session authentication or process owner.');
      const session = { ...old, version: 1, id, active: true, owner_pid: params.owner_pid, owner_identity: processIdentity(params.owner_pid), auth_hash: state.hash(params.token), run_id: params.run_id || null, run_root: params.run_root || null, phase_file: params.phase_file || null, context_limit: policy.contextLimit(state.config()), cwd: params.cwd, fixed_phase: params.fixed_phase, conversation_id: params.conversation_id || old.conversation_id || null };
      if (params.model) session.override = { model: policy.model(state.config(), params.model).id, scope: 'session', fallbacks: [] };
      if (params.mcp_scope) {
        const summary = {};
        for (const key of ['selected', 'omitted', 'missing_env']) {
          if (!Array.isArray(params.mcp_scope[key]) || params.mcp_scope[key].length > 300 || params.mcp_scope[key].some(name => typeof name !== 'string' || !/^[A-Za-z0-9_.-]{1,120}$/.test(name))) throw new Error('Invalid MCP scope summary.');
          summary[key] = params.mcp_scope[key];
        }
        session.mcp_scope = summary;
      } else delete session.mcp_scope;
      policy.route(state.config(), session);
      state.write(state.sessionFile(id), session);
      event(session, 'route.session_started', { context_limit: session.context_limit });
      return publicSession(session);
    });
    if (method === 'finish') return state.locked('sessions', () => {
      const session = state.read(state.sessionFile(params.id));
      if (session.auth_hash !== state.hash(params.token || '')) throw new Error('Session authentication failed.');
      session.active = false; state.write(state.sessionFile(session.id), session); return { stopped: true };
    });
    if (method === 'credential') {
      const ticket = this.tickets.get(params.ticket);
      if (!ticket || ticket.expires < Date.now() || ticket.provider !== params.provider) throw new Error('Account authorization is missing or expired.');
      return { headers: authHeaders(ticket.provider, ticket.credentials) };
    }
    if (method === 'usage') {
      const selected = params.account ? [state.getAccount(params.account)] : state.accounts();
      await Promise.all(selected.filter(item => item.enabled).map(async account => {
        try { const usage = await this.broker.usage(account); await this.updateAccount(account.id, item => { item.usage = usage; delete item.usage_error; }); }
        catch (error) { await this.updateAccount(account.id, item => { item.usage_error = 'unavailable'; if (error.reauth) item.status = 'reauth-required'; }); }
      }));
      return state.accounts();
    }
    if (method === 'route') return state.locked('sessions', () => {
      const session = this.findSession(params.session);
      const config = state.config();
      if (params.action === 'use') {
        session.override = { model: policy.model(config, params.model).id, scope: params.scope || 'session', phase: policy.phase(session), fallbacks: [] };
        if (!['session', 'phase'].includes(session.override.scope)) throw new Error('Scope must be phase or session.');
      } else if (params.action === 'auto') delete session.override;
      else if (params.action === 'pin') session.pinned_account = state.getAccount(params.account).id;
      else if (params.action === 'unpin') delete session.pinned_account;
      else if (params.action !== 'status') throw new Error('Unknown route action.');
      if (params.action !== 'status') {
        session.route_revision = state.token();
        delete session.current_route; delete session.last_rejection; delete session.paused_reason;
      }
      const selected = policy.route(config, session);
      if (session.pinned_account && state.getAccount(session.pinned_account).provider !== selected.models[0].provider) throw new Error('Pinned account does not serve this model. Unpin it first.');
      if (params.action !== 'status') { state.write(state.sessionFile(session.id), session); event(session, 'route.changed', { model: selected.models[0].id, phase: selected.phase, scope: session.override?.scope || 'auto' }); }
      return { session: publicSession(session), route: selected };
    });
    throw new Error('Unknown extension operation.');
  }
  findSession(id) {
    const matches = state.sessions().filter(item => active(item) && (!id || item.id === id));
    if (matches.length !== 1) throw new Error(matches.length ? 'Several sessions are active. Supply --session <id>.' : 'No matching routed session is running.');
    return matches[0];
  }
  async updateAccount(id, change) {
    return state.locked('accounts', () => { const items = state.accounts(); const found = items.find(item => item.id === id); if (found) { change(found); state.saveAccounts(items); } });
  }
  async markUnavailable(accountId, modelId, problem) {
    await this.updateAccount(accountId, item => {
      if (problem.reauth) item.status = 'reauth-required';
      else if (problem.modelOnly) {
        if (!(item.model_cooldowns?.[modelId] > problem.until)) {
          item.model_cooldowns = { ...item.model_cooldowns, [modelId]: problem.until };
          item.model_cooldown_reasons = { ...item.model_cooldown_reasons, [modelId]: problem.reason };
        }
      }
      else if (!(item.cooldown_until > problem.until)) { item.cooldown_until = problem.until; item.cooldown_reason = problem.reason; }
    });
  }
  authenticate(request) {
    const supplied = String(request.headers.authorization || request.headers['x-api-key'] || '').replace(/^Bearer /i, '');
    const session = state.sessions().find(item => item.auth_hash === state.hash(supplied) && active(item));
    if (!session) throw new Error('This request has no active Dex session authorization.');
    return session;
  }
  async handle(request, response) {
    const started = Date.now(), requestId = `dxreq_${require('node:crypto').randomUUID()}`;
    response.setHeader('x-dex-request-id', requestId);
    const controller = new AbortController();
    const abort = () => { if (!response.writableFinished) controller.abort(); };
    response.on('close', abort); this.inFlight.add(controller);
    let session, metrics, observer;
    try {
      session = this.authenticate(request);
      if (request.method === 'GET' && /\/models(?:\?|$)/.test(request.url)) {
        // Codex identifies itself with client_version and reads its own catalogue shape.
        const version = new URL(request.url, 'http://127.0.0.1').searchParams.get('client_version');
        if (session.client === 'codex' || version) {
          ipc.json(response, 200, await this.codexCatalog.models({ session, selected: policy.route(state.config(), session), accounts: state.accounts(), version })); return;
        }
        ipc.json(response, 200, { data: state.config().models.map(item => ({ id: item.id, type: 'model', display_name: item.id })) }); return;
      }
      const protocol = /\/v1\/responses(?:\?|$)/.test(request.url) ? 'responses' : 'messages';
      if (request.method !== 'POST' || !/\/v1\/(?:messages|responses)(?:\?|$)/.test(request.url)) { ipc.json(response, 404, { error: { type: 'not_found_error', message: 'Unsupported Dex gateway endpoint.' } }); return; }
      const body = await ipc.body(request, 32 * 1024 * 1024);
      metrics = { request_id: requestId, protocol, launch_context: session.context_limit,
        request_bytes: Buffer.byteLength(JSON.stringify(body)), tool_count: Array.isArray(body.tools) ? body.tools.length : 0,
        tool_schema_bytes: Buffer.byteLength(JSON.stringify(body.tools || [])), system_bytes: Buffer.byteLength(JSON.stringify(body.system || body.instructions || '')),
        attempts: 0 };
      const conversation = request.headers['x-claude-code-session-id'];
      if (conversation) {
        state.checkedId(conversation);
        // /clear, /resume and forks move a running client to another conversation.
        // The launch capability owns the session; the conversation is bookkeeping
        // that lets a resumed launch keep its route. Subagents keep the parent's.
        const childRequest = Boolean(request.headers['x-claude-code-parent-agent-id']);
        if (!childRequest && session.conversation_id !== conversation) {
          await state.locked('sessions', () => {
            const current = state.read(state.sessionFile(session.id));
            const previous = current.conversation_id || null;
            current.conversation_id = conversation; state.write(state.sessionFile(session.id), current);
            if (previous && previous !== conversation) event(session, 'route.conversation_changed', { from: previous, to: conversation });
          });
        }
      }
      const selected = policy.route(state.config(), session);
      // Native /model is an explicit request override; dex/active follows policy.
      // The provider checks whether the input fits a smaller model's window.
      // Claude Code carries its long-context marker in the model name.
      const picked = typeof body.model === 'string' ? require('./claude-picker.cjs').plainModel(body.model) : body.model;
      if (picked && picked !== 'dex/active') {
        const config = state.config();
        const matches = session.client && typeof picked === 'string' && !picked.includes('/') ? config.models.filter(item => (item.upstream_id || item.id.split('/')[1]) === picked) : [];
        if (matches.length > 1) throw new Error('Model name is ambiguous. Use the provider/model ID from dx model list.');
        const requested = policy.model(config, matches[0]?.id || picked);
        const configuredClientPrimary = session.client && config.client_routes?.[session.client]?.model;
        if (requested.id !== configuredClientPrimary) selected.models = [requested];
      }
      const currentRoute = policy.affinityKey(selected, protocol);
      const choices = policy.candidates(state.accounts(), selected, session, Date.now(), protocol);
      if (!choices.length) throw policy.unavailable(state.accounts(), selected, Date.now(), protocol);
      for (const choice of choices) {
        if (controller.signal.aborted) return;
        // Earlier attempts or concurrent sessions may have excluded this account.
        const account = state.accounts().find(item => item.id === choice.account.id);
        if (!account || policy.blockers(account, choice.model, Date.now(), protocol).length) continue;
        policy.validateRequest(body, choice.model, protocol);
        const cooldownKey = policy.cooldownKey(choice.model, protocol);
        let credentials;
        try { credentials = await this.broker.access(account); }
        catch (error) {
          await this.markUnavailable(account.id, cooldownKey, { reauth: error.reauth, reason: 'refresh-unavailable', until: Date.now() + 10000 });
          event(session, 'account.unavailable', { account_id: choice.account.id, reason: error.reauth ? 'reauth-required' : 'refresh-unavailable' });
          continue;
        }
        for (let authRetry = 0; authRetry < 2; authRetry++) {
          const next = structuredClone(body);
          prepareHistory(next, choice.model.provider, protocol);
          next.model = `dex-${choice.model.provider}/${choice.model.upstream_id || choice.model.id.split('/')[1]}`;
          if (choice.effort) {
            if (protocol === 'messages') next.output_config = { ...next.output_config, effort: choice.effort };
            else next.reasoning = { ...next.reasoning, effort: choice.effort };
          }
          const ticket = state.token();
          this.tickets.set(ticket, { provider: choice.account.provider, credentials, expires: Date.now() + 120000 });
          let upstream;
          try {
            Object.assign(metrics, { attempts: metrics.attempts + 1, account_id: account.id, model: choice.model.id,
              model_default_context: choice.model.default_context_window || choice.model.context_window, model_max_context: policy.modelCapacity(choice.model),
              model_pricing: choice.model.pricing,
              quota_age_ms: Number.isFinite(account.usage?.observed_at) ? Math.max(0, Date.now() - account.usage.observed_at) : null,
              quota_refresh_unavailable: Boolean(account.usage_error) });
            const headers = { 'content-type': 'application/json', authorization: `Bearer ${this.clientKey}`, 'x-ccr-dex-account-ticket': ticket };
            for (const key of ['anthropic-version', 'anthropic-beta', 'user-agent', 'x-claude-code-session-id', 'x-claude-code-agent-id', 'x-claude-code-parent-agent-id']) if (request.headers[key]) headers[key] = request.headers[key];
            upstream = await this.fetch(`${this.gateway}/v1/${protocol}`, { method: 'POST', headers, body: JSON.stringify(next), redirect: 'error', signal: controller.signal });
            metrics.provider_status = upstream.status;
            metrics.provider_request_id = providerRequestId(upstream.headers);
          } catch (error) {
            this.tickets.delete(ticket);
            if (controller.signal.aborted) return;
            await this.markUnavailable(account.id, cooldownKey, { reason: 'connection-failed', until: Date.now() + 10000 });
            event(session, 'router.request_failed', { reason: 'connection-failed', account_id: choice.account.id });
            break;
          }
          if (!upstream.ok) {
            let bytes = '';
            if (upstream.body) for await (const chunk of upstream.body) {
              bytes += Buffer.from(chunk).toString('utf8');
              if (Buffer.byteLength(bytes) > 65536) { bytes = ''; break; }
            }
            this.tickets.delete(ticket);
            let payload; try { payload = JSON.parse(bytes); } catch { payload = {}; }
            // CCR wraps the upstream error in its single-provider attempt record.
            const contextExceeded = contextError(payload, upstream.status);
            if (upstream.status === 400 && contextExceeded) {
              await this.recordRejection(session, choice.model.id, upstream.status);
              ipc.json(response, 400, { error: { type: 'invalid_request_error', code: 'context_length_exceeded',
                message: `${protocol === 'messages' ? 'prompt is too long: ' : ''}The conversation exceeds the selected model's context window. Compact it with /compact or select a model with a larger context window.`, provider_status: 400 } });
              return;
            }
            const termsRequired = termsAcceptanceRequired(payload, upstream.status, choice.model.provider);
            // Terms acceptance belongs to the account, not the request or model.
            // Retry it after a short interval so browser acceptance needs no reauth.
            let problem = termsRequired ? { retry: true, reason: 'terms-required', until: Date.now() + 60000 }
              : policy.failure(upstream.status, payload, upstream.headers);
            if (upstream.status === 401 && authRetry === 0) {
              try { credentials = await this.broker.access(choice.account, true); continue; }
              catch (error) { if (!error.reauth) problem = { retry: true, reason: 'refresh-unavailable', until: Date.now() + 10000 }; }
            }
            if (!problem.retry) {
              await this.recordRejection(session, choice.model.id, upstream.status);
              const detail = rejectionDetails(payload, upstream.status);
              const reason = detail.code || detail.type;
              const message = `${choice.model.id} rejected this request (HTTP ${upstream.status}${reason ? `; ${reason}` : ''}${detail.param ? ` at ${detail.param}` : ''}).`;
              event(session, 'router.request_rejected', { account_id: account.id, model: choice.model.id, protocol,
                provider_status: upstream.status, provider_error: detail });
              ipc.json(response, upstream.status, { error: { type: 'invalid_request_error', code: 'provider_request_rejected',
                message, provider_status: upstream.status, provider_error: detail } });
              return;
            }
            await this.markUnavailable(account.id, cooldownKey, problem);
            event(session, 'account.failover', { account_id: account.id, model: choice.model.id, protocol, reason: problem.reason,
              provider_status: upstream.status, provider_error: termsRequired ? { type: 'terms_acceptance_required', message: 'Accept the updated Consumer Terms and Privacy Policy in claude.ai for this account.' }
                : providerError(payload), scope: problem.modelOnly ? 'model' : 'account', retry_at: problem.until || null });
            break;
          }
          await state.locked('sessions', () => {
            const current = state.read(state.sessionFile(session.id));
            current.current_account = choice.account.id; current.current_model = choice.model.id; current.phase = selected.phase;
            if (current.route_revision === session.route_revision) current.current_route = currentRoute;
            delete current.paused_reason; delete current.last_rejection;
            state.write(state.sessionFile(session.id), current);
          });
          if (session.current_account !== choice.account.id || session.current_model !== choice.model.id || session.phase !== selected.phase) event(session, 'route.selected', { account_id: choice.account.id, model: choice.model.id, phase: selected.phase });
          response.writeHead(upstream.status, { 'content-type': upstream.headers.get('content-type') || 'application/json', 'cache-control': 'no-store', 'x-dex-model': choice.model.id });
          observer = responseMetrics(upstream.headers.get('content-type'));
          try {
            if (upstream.body) {
              const source = protocol === 'responses' && choice.model.provider === 'anthropic'
                ? Readable.from(prepareResponse(upstream.body, upstream.headers.get('content-type'))) : Readable.fromWeb(upstream.body);
              await pipeline(source, observer.stream, response);
            } else response.end();
          }
          finally { this.tickets.delete(ticket); }
          return;
        }
      }
      throw policy.unavailable(state.accounts(), selected, Date.now(), protocol);
    } catch (error) {
      if (session) {
        const reason = response.headersSent ? 'partial-response' : 'no-completed-response';
        try {
          await state.locked('sessions', () => { const current = state.read(state.sessionFile(session.id)); current.paused_reason = reason; state.write(state.sessionFile(session.id), current); });
          event(session, 'route.paused', { reason });
        } catch { /* An unsafe journal must not leave the HTTP request unresolved. */ }
      }
      if (!response.headersSent && !response.destroyed) {
        if (error.retryAfter) response.setHeader('retry-after', String(error.retryAfter));
        const unavailable = error.code === 'subscription_accounts_unavailable';
        ipc.json(response, session ? (unavailable ? error.status : 503) : 401, { error: { type: unavailable ? error.type : 'api_error', message: error.message,
          ...(unavailable ? { code: error.code } : {}),
          ...(error.retryAfter ? { retry_after_seconds: error.retryAfter } : {}) } });
      }
      else response.destroy();
    } finally {
      if (session && metrics) {
        const totals = observer?.totals || {};
        const saved = { ...metrics, ...totals, status: response.headersSent ? response.statusCode : 0,
          // Null when the model carries no recorded price, so an unpriced route
          // never reads as a free one.
          cost_usd: requestCost(metrics.model_pricing, totals),
          duration_ms: Math.max(0, Date.now() - started), timestamp: new Date().toISOString(), interrupted: !response.writableFinished };
        delete saved.model_pricing;
        const write = state.locked('sessions', () => {
          const current = state.read(state.sessionFile(session.id));
          current.last_request = saved; state.write(state.sessionFile(session.id), current);
          event(session, 'router.request_completed', saved);
        }).catch(() => { this.telemetryFailures++; });
        this.metricWrites.add(write);
        try { await write; } finally { this.metricWrites.delete(write); }
      }
      this.inFlight.delete(controller); response.off('close', abort);
    }
  }
  async recordRejection(session, model, status) {
    await state.locked('sessions', () => {
      const current = state.read(state.sessionFile(session.id));
      current.last_rejection = { model, status };
      delete current.paused_reason;
      state.write(state.sessionFile(session.id), current);
    });
  }
}
module.exports = { RouterService, processIdentity, active, publicSession, event };
