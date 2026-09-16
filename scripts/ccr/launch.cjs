'use strict';
const path = require('node:path');
const { spawn } = require('node:child_process');
const state = require('./state.cjs');
const adapter = require('./adapter.cjs');
const ipc = require('./ipc.cjs');

function launchArguments(args) {
  const forwarded = []; let requested;
  const delimiter = args.indexOf('--');
  const options = delimiter < 0 ? args : args.slice(0, delimiter);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === '--') { forwarded.push(...args.slice(index)); break; }
    if (['--model', '--fallback-model', '--permission-mode'].includes(arg)) {
      if (!args[index + 1]) throw new Error(`${arg} requires a value.`);
      if (arg === '--model' && args[index + 1] !== 'dex/active') requested = args[index + 1];
      index++; continue;
    }
    if (arg.startsWith('--model=')) { if (arg.slice(8) !== 'dex/active') requested = arg.slice(8); continue; }
    if (arg.startsWith('--fallback-model=') || arg.startsWith('--permission-mode=')) continue;
    if (arg !== '--dangerously-skip-permissions') forwarded.push(arg);
  }
  const resume = options.some(arg => ['--resume', '--continue', '-r', '-c'].includes(arg) || arg.startsWith('--resume=')) && !options.includes('--fork-session');
  return { requested, resume, args: ['--dangerously-skip-permissions', '--permission-mode', 'bypassPermissions', '--model', 'dex/active', ...forwarded] };
}
// Native routing installs an apiKeyHelper in Claude's user settings. Claude
// warns when that helper and ANTHROPIC_AUTH_TOKEN are both present, so a routed
// launch hands its token to the helper instead (native.cjs returns it).
function apiKeyHelperConfigured(original = process.env) {
  const file = path.join(original.CLAUDE_CONFIG_DIR || path.join(require('node:os').homedir(), '.claude'), 'settings.json');
  try { return typeof JSON.parse(require('node:fs').readFileSync(file, 'utf8')).apiKeyHelper === 'string'; } catch { return false; }
}
function launchEnvironment(settings, token, session, original = process.env, helper = apiKeyHelperConfigured(original)) {
  const env = { ...original };
  for (const name of Object.keys(env)) if (/^(ANTHROPIC_|OPENAI_|AZURE_OPENAI_|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_API_KEY_HELPER|CLAUDE_CODE_USE_|CLAUDE_CODE_SUBAGENT_MODEL|CCR_|DX_ROUTER_SESSION_)/.test(name)) delete env[name];
  Object.assign(env, {
    ANTHROPIC_BASE_URL: `${settings.gateway}/plugins/dex`, ...(helper ? {} : { ANTHROPIC_AUTH_TOKEN: token }),
    ANTHROPIC_CUSTOM_MODEL_OPTION: 'dex/active', ANTHROPIC_CUSTOM_MODEL_OPTION_NAME: 'Dex automatic route',
    ANTHROPIC_DEFAULT_OPUS_MODEL: 'dex/active', ANTHROPIC_DEFAULT_SONNET_MODEL: 'dex/active', ANTHROPIC_DEFAULT_HAIKU_MODEL: 'dex/active',
    CLAUDE_CODE_SUBAGENT_MODEL: 'dex/active', CLAUDE_CODE_MAX_CONTEXT_TOKENS: String(session.context_limit),
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: String(Number(original.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE) > 0
      ? Math.min(80, Number(original.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)) : 80),
    CLAUDE_CODE_STOP_HOOK_BLOCK_CAP: original.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP || '1000',
    DX_ROUTER_SESSION_ID: session.id, DX_ROUTER_SESSION_TOKEN: token, DX_PROVIDER_ENGINE: 'ccr', DX_PROVIDER_AGENT: 'claude', DX_PROVIDER_PROFILE: 'ccr-subscription',
    DEX_ROUTER_HOME: state.root()
  });
  return env;
}
function gatewayMonitor(session) {
  let checking = false, failures = 0, recoveries = 0, stopped = false, failed = false;
  const record = type => {
    try { require('./service.cjs').event(session, type, { attempt: recoveries }); }
    catch { /* The native client owns the terminal while recovery runs. */ }
  };
  return {
    async check() {
      if (checking || stopped || recoveries >= 2) return;
      checking = true;
      try {
        if (await adapter.health(true)) { failures = 0; failed = false; return; }
        if (stopped || ++failures < 3) return;
        if (await adapter.health(true, 10000)) { failures = 0; failed = false; return; }
        if (stopped) return;
        recoveries++; failures = 0;
        record('router.recovery_started');
        try { await adapter.start({ recovery: true }); failed = false; record('router.recovery_succeeded'); }
        catch { failed = true; record('router.recovery_failed'); }
      } finally { checking = false; }
    },
    stop() { stopped = true; },
    get failed() { return failed; }
  };
}
async function launch(args) {
  const parsed = launchArguments(args);
  const settings = await adapter.start();
  const token = state.token();
  const lifecycle = process.env.DEX_SESSION_ID;
  const interactive = process.env.DEX_PHASE_HANDOFF === 'inline' && process.env.DEX_HEADLESS_RUN !== '1' && !args.includes('-p') && !args.includes('--print');
  const id = interactive && lifecycle ? lifecycle : `${(lifecycle || 'standalone').slice(0, 150)}.${state.token().slice(0, 12)}`;
  // Review waves and assessments run under their own session ID but follow the
  // lifecycle that spawned them; only that policy session has a phase file.
  const policySession = process.env.DEX_POLICY_SESSION_ID || lifecycle;
  const phaseFile = policySession && process.env.DEX_SESSION_ONLY !== '1' ? path.join(process.env.DX_STATE_DIR || path.join(require('node:os').homedir(), '.claude', '.dex-phases'), `${state.checkedId(policySession)}.phase`) : null;
  const session = await ipc.call('register', { id, token, owner_pid: process.pid, cwd: process.cwd(), run_id: process.env.DEX_RUN_ID, run_root: process.env.DX_RUN_ROOT, phase_file: phaseFile, resume: parsed.resume,
    model: process.env.DX_MODEL_OVERRIDE || (parsed.requested && parsed.requested !== process.env.DX_CLAUDE_MODEL ? parsed.requested : undefined) });
  const monitor = gatewayMonitor(session);
  const watchdog = setInterval(() => { void monitor.check(); }, 3000);
  watchdog.unref();
  try {
    return await new Promise((resolve, reject) => {
      const child = spawn('claude', parsed.args, { stdio: 'inherit', env: launchEnvironment(settings, token, session) });
      const forward = signal => { if (!child.killed) child.kill(signal); };
      const interrupt = () => forward('SIGINT'); const terminate = () => forward('SIGTERM');
      process.on('SIGINT', interrupt); process.on('SIGTERM', terminate);
      const cleanup = () => { process.off('SIGINT', interrupt); process.off('SIGTERM', terminate); };
      child.once('error', error => { cleanup(); reject(error); });
      child.once('exit', (code, signal) => { cleanup(); resolve(code ?? (signal === 'SIGINT' ? 130 : 143)); });
    });
  } finally {
    monitor.stop(); clearInterval(watchdog);
    try { await ipc.call('finish', { id, token }); } catch { /* Owner death also invalidates the session capability. */ }
    if (monitor.failed && !await adapter.health(true, 10000)) process.stderr.write('dex: CCR recovery failed. Run dx router doctor before resuming this conversation.\n');
  }
}
module.exports = { launchArguments, launchEnvironment, gatewayMonitor, launch };
