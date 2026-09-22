#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const packages = { playwright: '@playwright/mcp@latest', 'chrome-devtools': 'chrome-devtools-mcp@latest' };
// A caller that named its own profile, or an already-running browser, keeps it.
const profileArgument = /^--(?:isolated|user-data-dir|userDataDir|cdp-endpoint|browserUrl)(?:=|$)/;
function playwright(env = process.env) {
  const directory = path.join(env.DX_TOOL_DIR || path.join(os.homedir(), '.claude/.dex-tools'), 'ui-capture/node_modules/playwright');
  try { return require(directory); }
  catch { throw new Error('Browser tooling is missing. Run dx ui-capture install.'); }
}
// The browser profile directory for this provider session, or '' when there is
// no session to tie it to. DX_SESSION_TMP is the per-session temp root Dex
// removes when the session ends, so a profile under it cannot outlive the phase
// that opened it, and the path is recorded so a cleanup sweep can name what was
// minted. Without DX_SESSION_TMP nothing changes.
function profile(name, args = [], env = process.env) {
  const root = env.DX_SESSION_TMP;
  if (!packages[name] || !root || !path.isAbsolute(root)) return '';
  if (args.some(arg => profileArgument.test(arg))) return '';
  const directory = path.join(root, `browser-${name}`);
  try {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const record = path.join(root, 'browser-profiles.txt');
    const recorded = fs.existsSync(record) ? fs.readFileSync(record, 'utf8').split('\n') : [];
    if (!recorded.includes(directory)) fs.appendFileSync(record, `${directory}\n`, { mode: 0o600 });
  } catch { return ''; }
  return directory;
}
function command(name, args = [], env = process.env, session = '') {
  if (!packages[name]) throw new Error('Expected playwright or chrome-devtools.');
  const executable = playwright(env).chromium.executablePath();
  if (!fs.existsSync(executable)) throw new Error('Chromium is missing. Run dx ui-capture install.');
  const options = name === 'playwright' ? ['--executable-path', executable] : ['--executablePath', executable];
  if (!args.some(arg => profileArgument.test(arg))) {
    // Both servers take a profile directory and both refuse it alongside
    // --isolated; they only spell the flag differently.
    if (session) options.push(name === 'playwright' ? `--user-data-dir=${session}` : `--userDataDir=${session}`);
    else options.push('--isolated');
  }
  if (process.platform === 'linux' && !env.DISPLAY && !env.WAYLAND_DISPLAY) options.push('--headless');
  return ['npx', '-y', packages[name], ...options, ...args];
}
function run(argv) {
  const grouped = process.platform !== 'win32';
  const child = spawn(argv[0], argv.slice(1), { stdio: 'inherit', detached: grouped });
  const listeners = new Map(['SIGINT', 'SIGTERM', 'SIGHUP'].map(signal => [signal, () => {
    if (!child.pid) return;
    try { if (grouped) process.kill(-child.pid, signal); else child.kill(signal); }
    catch { /* The MCP may have already exited. */ }
  }]));
  for (const [signal, listener] of listeners) process.on(signal, listener);
  child.on('error', () => { console.error('Could not start browser MCP. Check Node.js and npx.'); process.exitCode = 1; });
  child.on('close', code => {
    for (const [signal, listener] of listeners) process.removeListener(signal, listener);
    process.exitCode = code ?? 1;
  });
  return child;
}
if (require.main === module) {
  try {
    const [name, ...args] = process.argv.slice(2);
    run(command(name, args, process.env, profile(name, args)));
  }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { playwright, profile, command, run, packages };
