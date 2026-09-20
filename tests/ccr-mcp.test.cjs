'use strict';
// Sandbox the router home before any scripts/ccr module can resolve it.
// This suite does not reach live state today; tests/ccr-test-isolation.py
// does not depend on that staying true. An outer sandbox wins.
process.env.DEX_ROUTER_HOME ||= require('node:path').join(require('node:os').tmpdir(), 'dex-ccr-unused-state');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scope } = require('../scripts/ccr/mcp-scope.cjs');
const { launchArguments } = require('../scripts/ccr/launch.cjs');

test('scoped MCP loading selects approved servers, honors local overrides and retains original configuration', t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-mcp-scope-')); t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const cwd = path.join(home, 'repo'); fs.mkdirSync(cwd);
  const file = path.join(home, '.claude.json');
  const config = { mcpServers: { playwright: { command: 'native-browser' }, 'chrome-devtools': { command: 'other-browser' }, 'devbox-other-db': { url: 'http://other-vm' }, 'linear-server': { url: 'https://linear' } },
    projects: { [cwd]: { mcpServers: { playwright: { command: 'local-browser' } } } } };
  fs.writeFileSync(file, JSON.stringify(config));
  const project = { mcpServers: { github: { type: 'http', url: 'https://github', headers: { Authorization: 'Bearer ${GITHUB_TOKEN}' } }, linear: { url: 'https://linear' } } };
  fs.writeFileSync(path.join(cwd, '.mcp.json'), JSON.stringify(project));
  const result = scope({ enabled: true, include: ['playwright', 'github', 'linear', 'linear-server', 'devbox-db'] }, { home, cwd, root: cwd, env: {} });
  assert.deepEqual(Object.keys(result.config.mcpServers).sort(), ['github', 'linear', 'playwright']);
  assert.equal(result.config.mcpServers.playwright.command, 'local-browser');
  assert.deepEqual(result.summary.missing_env, ['GITHUB_TOKEN']);
  assert.ok(result.summary.omitted.includes('devbox-other-db'));
  assert.deepEqual(JSON.parse(fs.readFileSync(file)), config);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(cwd, '.mcp.json'))), project);
  assert.doesNotMatch(JSON.stringify(result.summary), /Bearer|https:\/\//);
  config.projects[cwd].disabledMcpServers = ['playwright', 'linear'];
  config.projects[cwd].disabledMcpjsonServers = ['github'];
  config.mcpServers.disabled = { command: 'disabled-tool', enabled: false };
  config.mcpServers.hidden = { command: 'disabled-tool', disabled: true };
  config.mcpServers.globallyDisabled = { command: 'disabled-tool' };
  config.disabledMcpServers = ['globallyDisabled'];
  Object.defineProperty(config.mcpServers, '__proto__', { value: { command: 'ordinary-tool' }, enumerable: true });
  fs.writeFileSync(file, JSON.stringify(config));
  const disabled = scope({ enabled: true, include: ['playwright', 'github', 'linear', 'linear-server', 'disabled', 'hidden', 'globallyDisabled', '__proto__'] }, { home, cwd, root: cwd, env: {} });
  assert.deepEqual(disabled.summary.selected.sort(), ['__proto__', 'linear-server']);
  assert.equal(JSON.parse(JSON.stringify(disabled.config)).mcpServers.__proto__.command, 'ordinary-tool');
});
test('scoping is opt-in and explicit native MCP flags take precedence', () => {
  assert.equal(scope(undefined), null);
  assert.equal(scope({ enabled: false }), null);
  assert.throws(() => scope({ enabled: true, include: '*' }), /include/);
  assert.throws(() => scope({ enabled: true, include: ['bad\nname'] }), /name/);
  assert.equal(launchArguments(['--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}']).mcpExplicit, true);
  assert.equal(launchArguments(['--', '--mcp-config']).mcpExplicit, false);
});

test('linked worktrees retain servers disabled in the main checkout', t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-mcp-worktree-')); t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const repo = fs.realpathSync(home);
  const git = args => { const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' }); assert.equal(result.status, 0, result.stderr); };
  git(['init', '-q']);
  fs.writeFileSync(path.join(repo, '.mcp.json'), JSON.stringify({ mcpServers: { github: { url: 'https://github' }, linear: { url: 'https://linear' } } }));
  git(['add', '.mcp.json']);
  git(['-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'fixture']);
  const cwd = path.join(repo, 'ticket'); git(['worktree', 'add', '--detach', cwd, 'HEAD']);
  fs.writeFileSync(path.join(home, '.claude.json'), JSON.stringify({ projects: { [repo]: { disabledMcpServers: ['github'] }, [cwd]: {} } }));
  const result = scope({ enabled: true, include: ['github', 'linear'] }, { home, cwd, env: {} });
  assert.deepEqual(result.summary.selected, ['linear']);
  assert.ok(result.summary.omitted.includes('github'));
});
