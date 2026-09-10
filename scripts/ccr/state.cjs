'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const VERSION = 1;
const ID = /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,179}$/;
const root = () => path.resolve(process.env.DEX_ROUTER_HOME || path.join(os.homedir(), '.dex', 'router'));
const token = () => crypto.randomBytes(32).toString('base64url');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');

function privateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Router storage must be an owned directory.');
  fs.chmodSync(dir, 0o700);
  return dir;
}

function read(file, fallback) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw new Error('Router state has unsafe permissions.');
    if (stat.size > 8 * 1024 * 1024) throw new Error('Router state exceeds its size limit.');
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT' && fallback !== undefined) return structuredClone(fallback);
    throw error;
  }
}

function write(file, data) {
  privateDir(path.dirname(file));
  const temp = `${file}.${token()}.tmp`;
  let fd;
  try {
    fd = fs.openSync(temp, 'wx', 0o600);
    fs.writeFileSync(fd, `${JSON.stringify(data, null, 2)}\n`);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temp, file);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    fs.rmSync(temp, { force: true });
  }
}

function checkedId(value) {
  if (typeof value !== 'string' || !ID.test(value)) throw new Error('Invalid account or session identifier.');
  return value;
}

function stateFile(kind) { return path.join(root(), `${checkedId(kind)}.json`); }
function backend(fallback) {
  const metadata = read(stateFile('backend'), fallback);
  if (!metadata) return metadata;
  return { ...metadata, ...read(path.join(root(), 'credentials', 'local-transport.json')) };
}
function saveBackend(settings) {
  const { management_key, client_key, ...metadata } = settings;
  write(path.join(root(), 'credentials', 'local-transport.json'), { management_key, client_key });
  write(stateFile('backend'), metadata);
}
function config() {
  const data = read(stateFile('config'), { version: VERSION, enabled: false, models: [], phases: {} });
  if (data.version !== VERSION || !Array.isArray(data.models) || !data.phases || typeof data.enabled !== 'boolean') throw new Error('Unsupported router configuration.');
  return data;
}
function accounts() {
  const data = read(stateFile('accounts'), { version: VERSION, accounts: [] });
  if (data.version !== VERSION || !Array.isArray(data.accounts)) throw new Error('Unsupported account registry.');
  return data.accounts;
}
function saveAccounts(items) { write(stateFile('accounts'), { version: VERSION, accounts: items }); }
function sessionFile(id) { return path.join(root(), 'sessions', `${checkedId(id)}.json`); }
function sessions() {
  const dir = path.join(root(), 'sessions');
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter(name => name.endsWith('.json')).map(name => read(path.join(dir, name)));
}
function getAccount(selector, items = accounts()) {
  const matches = items.filter(item => item.id === selector || item.name === selector);
  if (matches.length !== 1) throw new Error(matches.length ? 'Account name is ambiguous; use its ID.' : 'Account not found. Run dx accounts.');
  return matches[0];
}

// flock survives neither process death nor reboot; its file remains in place so
// a stale-owner cleanup cannot accidentally unlink another writer's lock.
async function locked(name, action) {
  privateDir(root());
  const lock = path.join(root(), `${checkedId(name)}.lock`);
  const child = spawn('python3', [path.join(__dirname, 'native.py'), 'lock', lock], { stdio: ['pipe', 'pipe', 'pipe'] });
  try {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { child.kill(); reject(new Error('Router state is busy. Retry the command.')); }, 15000);
      child.once('error', error => { clearTimeout(timeout); reject(error); });
      child.once('exit', () => { clearTimeout(timeout); reject(new Error('Could not acquire the router state lock.')); });
      child.stdout.once('data', () => { clearTimeout(timeout); resolve(); });
    });
    return await action();
  } finally { child.stdin.end(); }
}

module.exports = { VERSION, root, token, hash, privateDir, read, write, checkedId, stateFile, backend, saveBackend, config, accounts, saveAccounts, sessionFile, sessions, getAccount, locked };
