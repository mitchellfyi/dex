#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const packages = { playwright: '@playwright/mcp@latest', 'chrome-devtools': 'chrome-devtools-mcp@latest' };
function playwright(env = process.env) {
  const directory = path.join(env.DX_TOOL_DIR || path.join(os.homedir(), '.claude/.dex-tools'), 'ui-capture/node_modules/playwright');
  try { return require(directory); }
  catch { throw new Error('Browser tooling is missing. Run dx ui-capture install.'); }
}
function command(name, args = [], env = process.env) {
  if (!packages[name]) throw new Error('Expected playwright or chrome-devtools.');
  const executable = playwright(env).chromium.executablePath();
  if (!fs.existsSync(executable)) throw new Error('Chromium is missing. Run dx ui-capture install.');
  const options = name === 'playwright' ? ['--executable-path', executable] : ['--executablePath', executable];
  if (process.platform === 'linux' && !env.DISPLAY && !env.WAYLAND_DISPLAY) options.push('--headless');
  return ['npx', '-y', packages[name], ...options, ...args];
}
function run(argv) {
  const child = spawn(argv[0], argv.slice(1), { stdio: 'inherit' });
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => child.kill(signal));
  child.on('error', () => { console.error('Could not start browser MCP. Check Node.js and npx.'); process.exitCode = 1; });
  child.on('exit', code => { process.exitCode = code ?? 1; });
  return child;
}
if (require.main === module) {
  try { run(command(process.argv[2], process.argv.slice(3))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { playwright, command, run, packages };
