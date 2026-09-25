'use strict';
// The router's own sources, as the running gateway sees them. Kept free of
// other Dex modules so the extension shim can load it once and keep it.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const Module = require('node:module');

function sources(directory = __dirname) {
  // Diagnostics must survive an unreadable checkout: no names reports nothing
  // stale rather than failing dx router status, which is what someone runs first.
  try { return fs.readdirSync(directory).filter(name => name.endsWith('.cjs')).map(name => path.join(directory, name)); } catch { return []; }
}
// When the router's own sources were last edited. A running gateway keeps
// serving the code it loaded until the extension reloads it, so comparing this
// with the load time is how a caller tells the two apart.
function sourceChangedAt(directory = __dirname) {
  let newest = 0;
  for (const file of sources(directory)) {
    try { newest = Math.max(newest, fs.statSync(file).mtimeMs); } catch { /* A file racing a Dex update is not a staleness signal. */ }
  }
  return newest;
}
// Identifies the exact set of sources. The newest mtime alone misses a file
// replaced with an older timestamp (cp -p, an extracted archive), and a deleted one.
function sourceRevision(directory = __dirname) {
  const hash = crypto.createHash('sha256');
  for (const file of sources(directory).sort()) {
    try { const stat = fs.statSync(file); hash.update(`${path.basename(file)}:${stat.mtimeMs}:${stat.size}\n`); } catch { /* Gone since the listing; the next look sees it. */ }
  }
  return hash.digest('hex').slice(0, 16);
}
// Compiles every source without running it, so a half-saved file is refused
// before any module is replaced. It cannot see a file that parses but is wrong.
function checkSources(directory = __dirname) {
  // Node drops a leading #! line itself; inside the wrapper it would not parse.
  for (const file of sources(directory)) new vm.Script(Module.wrap(fs.readFileSync(file, 'utf8').replace(/^#!.*/, '')), { filename: file });
}
// A checkout or rebase rewrites several files in turn; loading midway would mix
// two revisions. Worktrees keep their index under the gitdir a .git file names.
function gitBusy(directory = __dirname) {
  const top = path.resolve(directory, '..', '..');
  let gitdir = path.join(top, '.git');
  try {
    if (fs.statSync(gitdir).isFile()) gitdir = path.resolve(top, fs.readFileSync(gitdir, 'utf8').replace(/^gitdir:\s*/, '').trim());
  } catch { return false; }
  return fs.existsSync(path.join(gitdir, 'index.lock'));
}
module.exports = { sources, sourceChangedAt, sourceRevision, checkSources, gitBusy };
