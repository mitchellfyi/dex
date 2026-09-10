'use strict';
const path = require('node:path');
const { spawn } = require('node:child_process');
const state = require('./state.cjs');
const adapter = require('./adapter.cjs');
const ipc = require('./ipc.cjs');

function launchArguments(args) {
  const forwarded = []; let requested;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (['--model', '--fallback-model', '--permission-mode'].includes(arg)) {
      if (!args[index + 1]) throw new Error(`${arg} requires a value.`);
      if (arg === '--model' && args[index + 1] !== 'dex/active') requested = args[index + 1];
      index++; continue;
    }
    if (arg.startsWith('--model=')) { if (arg.slice(8) !== 'dex/active') requested = arg.slice(8); continue; }
    if (arg.startsWith('--fallback-model=') || arg.startsWith('--permission-mode=')) continue;
    if (arg !== '--dangerously-skip-permissions') forwarded.push(arg);
  }
  return { requested, args: ['--dangerously-skip-permissions', '--permission-mode', 'bypassPermissions', '--model', 'dex/active', ...forwarded] };
}
function launchEnvironment(settings, token, session, original = process.env) {
  const env = { ...original };
  for (const name of Object.keys(env)) if (/^(ANTHROPIC_|OPENAI_|AZURE_OPENAI_|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_API_KEY_HELPER|CLAUDE_CODE_USE_|CLAUDE_CODE_SUBAGENT_MODEL|CCR_)/.test(name)) delete env[name];
  Object.assign(env, {
    ANTHROPIC_BASE_URL: `${settings.gateway}/plugins/dex`, ANTHROPIC_AUTH_TOKEN: token,
    ANTHROPIC_CUSTOM_MODEL_OPTION: 'dex/active', ANTHROPIC_CUSTOM_MODEL_OPTION_NAME: 'Dex automatic route',
    ANTHROPIC_DEFAULT_OPUS_MODEL: 'dex/active', ANTHROPIC_DEFAULT_SONNET_MODEL: 'dex/active', ANTHROPIC_DEFAULT_HAIKU_MODEL: 'dex/active',
    CLAUDE_CODE_SUBAGENT_MODEL: 'dex/active', CLAUDE_CODE_MAX_CONTEXT_TOKENS: String(session.context_limit),
    CLAUDE_CODE_STOP_HOOK_BLOCK_CAP: original.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP || '1000',
    DX_ROUTER_SESSION_ID: session.id, DX_PROVIDER_ENGINE: 'ccr', DX_PROVIDER_AGENT: 'claude', DX_PROVIDER_PROFILE: 'ccr-subscription',
    DEX_ROUTER_HOME: state.root()
  });
  return env;
}
async function launch(args) {
  const parsed = launchArguments(args);
  const settings = await adapter.start();
  const token = state.token();
  const lifecycle = process.env.DEX_SESSION_ID;
  const interactive = process.env.DEX_PHASE_HANDOFF === 'inline' && process.env.DEX_HEADLESS_RUN !== '1' && !args.includes('-p') && !args.includes('--print');
  const id = interactive && lifecycle ? lifecycle : `${(lifecycle || 'standalone').slice(0, 150)}.${state.token().slice(0, 12)}`;
  const phaseFile = lifecycle ? path.join(process.env.DX_STATE_DIR || path.join(require('node:os').homedir(), '.claude', '.dex-phases'), `${state.checkedId(lifecycle)}.phase`) : null;
  const session = await ipc.call('register', { id, token, owner_pid: process.pid, cwd: process.cwd(), run_id: process.env.DEX_RUN_ID, run_root: process.env.DX_RUN_ROOT, phase_file: phaseFile,
    model: process.env.DX_MODEL_OVERRIDE || (parsed.requested && parsed.requested !== process.env.DX_CLAUDE_MODEL ? parsed.requested : undefined) });
  let monitoring = false; let failures = 0; let recoveries = 0; let stopped = false;
  const watchdog = setInterval(async () => {
    if (monitoring || stopped || recoveries >= 2) return;
    monitoring = true;
    try {
      if (await adapter.health(true)) { failures = 0; return; }
      if (++failures < 3) return;
      recoveries++; failures = 0;
      process.stderr.write('[info]  Recovering the local CCR gateway; this conversation is preserved.\n');
      await adapter.start({ recovery: true });
    } catch { process.stderr.write('[warn]  CCR recovery failed. Run dx router doctor; resume the conversation after recovery.\n'); }
    finally { monitoring = false; }
  }, 3000);
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
    stopped = true; clearInterval(watchdog);
    try { await ipc.call('finish', { id, token }); } catch { /* Owner death also invalidates the session capability. */ }
  }
}
module.exports = { launchArguments, launchEnvironment, launch };
