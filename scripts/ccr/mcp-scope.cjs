'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function read(file) {
  try {
    const info = fs.statSync(file);
    if (!info.isFile() || info.size > 4 * 1024 * 1024) throw new Error('invalid size');
    const result = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('invalid object');
    return result;
  } catch (error) {
    if (error.code === 'ENOENT') return {};
    throw new Error(`Cannot read MCP configuration at ${file}. Correct it before launching a scoped session.`);
  }
}

function scope(policy, { home = os.homedir(), cwd = process.cwd(), root, env = process.env } = {}) {
  if (!policy?.enabled) return null;
  if (!Array.isArray(policy.include)) throw new Error('MCP scope requires an include array of server names.');
  if (policy.include.some(name => typeof name !== 'string' || !/^[A-Za-z0-9_.-]{1,120}$/.test(name))) throw new Error('Invalid MCP server name in scope.');
  if (policy.builtin_tools !== undefined && (!Array.isArray(policy.builtin_tools) || policy.builtin_tools.some(name => typeof name !== 'string' || !/^[A-Za-z][A-Za-z0-9]{0,80}$/.test(name)))) throw new Error('Invalid builtin_tools in MCP scope.');
  if (!root) {
    const result = spawnSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', timeout: 3000, maxBuffer: 8192 });
    root = result.status === 0 ? result.stdout.trim() : cwd;
  }
  const globalFile = env.CLAUDE_CONFIG_DIR ? path.join(env.CLAUDE_CONFIG_DIR, '.claude.json') : path.join(home, '.claude.json');
  const user = read(globalFile), project = read(path.join(root, '.mcp.json'));
  const local = user.projects?.[cwd]?.mcpServers || user.projects?.[root]?.mcpServers || {};
  const available = { ...user.mcpServers, ...project.mcpServers, ...local };
  const included = new Set(policy.include), selected = {}, omitted = [], missing = new Set();
  if (available.linear && included.has('linear')) included.delete('linear-server');
  for (const [name, entry] of Object.entries(available)) {
    if (!included.has(name)) { omitted.push(name); continue; }
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw new Error(`Invalid configuration for MCP server ${name}.`);
    selected[name] = entry;
    for (const match of JSON.stringify(entry).matchAll(/\$\{([A-Z_][A-Z0-9_]*)\}/g)) if (!env[match[1]]) missing.add(match[1]);
  }
  return { config: { mcpServers: selected }, summary: { selected: Object.keys(selected), omitted, missing_env: [...missing] }, builtin_tools: policy.builtin_tools };
}
module.exports = { scope };
