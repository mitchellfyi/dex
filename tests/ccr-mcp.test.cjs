'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { scope } = require('../scripts/ccr/mcp-scope.cjs');
const { launchArguments } = require('../scripts/ccr/launch.cjs');

test('scoped MCP loading selects approved servers, honors local overrides and retains original configuration', t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-mcp-scope-')); t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const cwd = path.join(home, 'repo'); fs.mkdirSync(cwd);
  const file = path.join(home, '.claude.json');
  const config = { mcpServers: { playwright: { command: 'native-browser' }, 'chrome-devtools': { command: 'other-browser' }, 'devserver-other-db': { url: 'http://other-vm' }, 'linear-server': { url: 'https://linear' } },
    projects: { [cwd]: { mcpServers: { playwright: { command: 'local-browser' } } } } };
  fs.writeFileSync(file, JSON.stringify(config));
  const project = { mcpServers: { github: { type: 'http', url: 'https://github', headers: { Authorization: 'Bearer ${GITHUB_TOKEN}' } }, linear: { url: 'https://linear' } } };
  fs.writeFileSync(path.join(cwd, '.mcp.json'), JSON.stringify(project));
  const result = scope({ enabled: true, include: ['playwright', 'github', 'linear', 'linear-server', 'devserver-db'] }, { home, cwd, root: cwd, env: {} });
  assert.deepEqual(Object.keys(result.config.mcpServers).sort(), ['github', 'linear', 'playwright']);
  assert.equal(result.config.mcpServers.playwright.command, 'local-browser');
  assert.deepEqual(result.summary.missing_env, ['GITHUB_TOKEN']);
  assert.ok(result.summary.omitted.includes('devserver-other-db'));
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
