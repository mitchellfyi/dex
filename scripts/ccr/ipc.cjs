'use strict';
const http = require('node:http');
const path = require('node:path');
const state = require('./state.cjs');

// Unix socket paths are short on macOS. The private directory authenticates
// local callers by UID; session credentials authenticate model requests.
function socketPath() {
  // TMPDIR may be an arbitrarily deep worktree/test directory. macOS accepts
  // at most 104 bytes for a Unix socket path, so use a private short directory.
  const dir = path.join('/tmp', `dex-ccr-${process.getuid()}-${state.hash(state.root()).slice(0,16)}`);
  state.privateDir(dir);
  return path.join(dir, 'control.sock');
}
async function body(request, limit = 8 * 1024 * 1024) {
  const chunks = []; let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw new Error('Request exceeds the local size limit.');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}
function json(response, code, data) {
  response.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(data));
}
function call(method, params = {}, timeout = 30000) {
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath: socketPath(), path: '/dex/v1', method: 'POST', headers: { 'content-type': 'application/json' } }, async response => {
      try { const result = await body(response); if (response.statusCode !== 200) reject(new Error(result.error || 'Router request failed.')); else resolve(result); } catch (error) { reject(error); }
    });
    request.setTimeout(timeout, () => request.destroy(new Error('Router request timed out.')));
    request.on('error', error => reject(new Error(error.code === 'ENOENT' || error.code === 'ECONNREFUSED' ? 'Router is not running. Run dx router start.' : error.message)));
    request.end(JSON.stringify({ version: 1, method, params }));
  });
}
module.exports = { socketPath, body, json, call };
