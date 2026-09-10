'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const state = require('./state.cjs');
const policy = require('./policy.cjs');
const ipc = require('./ipc.cjs');
const { AccountBroker, authHeaders } = require('./accounts.cjs');

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
    this.tickets.clear();
    if (this.server) await new Promise(resolve => this.server.close(resolve));
  }
  async control(method, params) {
    if (method === 'health') return { version: 1, extension: 'dex-ccr', pid: process.pid, owner_identity: processIdentity(process.pid), active_requests: this.inFlight.size, active_sessions: state.sessions().filter(active).length };
    if (method === 'sessions') return state.sessions().map(publicSession);
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
  authenticate(request) {
    const supplied = String(request.headers.authorization || request.headers['x-api-key'] || '').replace(/^Bearer /i, '');
    const session = state.sessions().find(item => item.auth_hash === state.hash(supplied) && active(item));
    if (!session) throw new Error('This request has no active Dex session authorization.');
    return session;
  }
  async handle(request, response) {
    const controller = new AbortController();
    const abort = () => { if (!response.writableFinished) controller.abort(); };
    response.on('close', abort); this.inFlight.add(controller);
    let session;
    try {
      session = this.authenticate(request);
      if (request.method === 'GET' && /\/models(?:\?|$)/.test(request.url)) {
        ipc.json(response, 200, { data: state.config().models.map(item => ({ id: item.id, type: 'model', display_name: item.id })) }); return;
      }
      if (request.method !== 'POST' || !/\/v1\/messages(?:\?|$)/.test(request.url)) { ipc.json(response, 404, { error: { type: 'not_found_error', message: 'Unsupported Dex gateway endpoint.' } }); return; }
      const body = await ipc.body(request, 32 * 1024 * 1024);
      const conversation = request.headers['x-claude-code-session-id'];
      if (conversation) {
        state.checkedId(conversation);
        const childRequest = Boolean(request.headers['x-claude-code-parent-agent-id']);
        if (!childRequest && session.conversation_id && session.conversation_id !== conversation) throw new Error('Claude conversation does not match its Dex session.');
        if (!childRequest) await state.locked('sessions', () => { const current = state.read(state.sessionFile(session.id)); current.conversation_id = conversation; state.write(state.sessionFile(session.id), current); });
      }
      const selected = policy.route(state.config(), session);
      // Native /model is an explicit request override; dex/active follows policy.
      if (body.model && body.model !== 'dex/active') {
        selected.models = [policy.model(state.config(), body.model)];
        if (selected.models[0].context_window < session.context_limit) throw new Error('Compact and restart before selecting a smaller context model.');
      }
      const choices = policy.candidates(state.accounts(), selected, session);
      if (!choices.length) throw new Error('No eligible subscription accounts. Run dx accounts, reauthenticate an account, or select another route.');
      for (const choice of choices) {
        if (controller.signal.aborted) return;
        policy.validateRequest(body, choice.model);
        let credentials;
        try { credentials = await this.broker.access(choice.account); }
        catch (error) {
          if (error.reauth) await this.updateAccount(choice.account.id, item => { item.status = 'reauth-required'; });
          event(session, 'account.unavailable', { account_id: choice.account.id, reason: error.reauth ? 'reauth-required' : 'refresh-unavailable' });
          continue;
        }
        for (let authRetry = 0; authRetry < 2; authRetry++) {
          const ticket = state.token();
          this.tickets.set(ticket, { provider: choice.account.provider, credentials, expires: Date.now() + 120000 });
          let upstream;
          try {
            const headers = { 'content-type': 'application/json', authorization: `Bearer ${this.clientKey}`, 'x-ccr-dex-account-ticket': ticket };
            for (const key of ['anthropic-version', 'anthropic-beta', 'user-agent', 'x-claude-code-session-id', 'x-claude-code-agent-id', 'x-claude-code-parent-agent-id']) if (request.headers[key]) headers[key] = request.headers[key];
            const next = structuredClone(body);
            next.model = `dex-${choice.model.provider}/${choice.model.upstream_id || choice.model.id.split('/')[1]}`;
            if (choice.effort) {
              if (choice.model.provider === 'anthropic') next.output_config = { ...next.output_config, effort: choice.effort };
              else next.reasoning = { effort: choice.effort };
            }
            upstream = await this.fetch(`${this.gateway}/v1/messages`, { method: 'POST', headers, body: JSON.stringify(next), redirect: 'error', signal: controller.signal });
          } catch (error) {
            this.tickets.delete(ticket);
            if (controller.signal.aborted) return;
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
            let problem = policy.failure(upstream.status, payload, upstream.headers);
            if (upstream.status === 401 && authRetry === 0) {
              try { credentials = await this.broker.access(choice.account, true); continue; }
              catch (error) { if (!error.reauth) problem = { retry: true, reason: 'refresh-unavailable', until: Date.now() + 10000 }; }
            }
            if (!problem.retry) { ipc.json(response, upstream.status, { error: { type: 'invalid_request_error', message: 'The provider rejected this request. Check the selected model and supported content.', provider_status: upstream.status } }); return; }
            await this.updateAccount(choice.account.id, item => {
              if (problem.reauth) item.status = 'reauth-required';
              else if (problem.modelOnly) item.model_cooldowns = { ...item.model_cooldowns, [choice.model.id]: problem.until };
              else item.cooldown_until = problem.until;
            });
            event(session, 'account.failover', { account_id: choice.account.id, model: choice.model.id, reason: problem.reason });
            break;
          }
          await state.locked('sessions', () => {
            const current = state.read(state.sessionFile(session.id));
            current.current_account = choice.account.id; current.current_model = choice.model.id; current.phase = selected.phase;
            delete current.paused_reason;
            state.write(state.sessionFile(session.id), current);
          });
          if (session.current_account !== choice.account.id || session.current_model !== choice.model.id || session.phase !== selected.phase) event(session, 'route.selected', { account_id: choice.account.id, model: choice.model.id, phase: selected.phase });
          response.writeHead(upstream.status, { 'content-type': upstream.headers.get('content-type') || 'application/json', 'cache-control': 'no-store', 'x-dex-model': choice.model.id });
          try { if (upstream.body) await pipeline(Readable.fromWeb(upstream.body), response); else response.end(); }
          finally { this.tickets.delete(ticket); }
          return;
        }
      }
      throw new Error('All eligible routes are unavailable. Your session is preserved; use dx accounts or dx route use to recover.');
    } catch (error) {
      if (session) {
        const reason = response.headersSent ? 'partial-response' : 'no-completed-response';
        try {
          await state.locked('sessions', () => { const current = state.read(state.sessionFile(session.id)); current.paused_reason = reason; state.write(state.sessionFile(session.id), current); });
          event(session, 'route.paused', { reason });
        } catch { /* An unsafe journal must not leave the HTTP request unresolved. */ }
      }
      if (!response.headersSent && !response.destroyed) ipc.json(response, session ? 503 : 401, { error: { type: 'api_error', message: error.message } });
      else response.destroy();
    } finally { this.inFlight.delete(controller); response.off('close', abort); }
  }
}
module.exports = { RouterService, processIdentity, active, publicSession, event };
