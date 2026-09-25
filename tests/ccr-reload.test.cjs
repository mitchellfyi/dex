'use strict';
// Drives the extension shim against a private copy of scripts/ccr, so the test
// can edit the sources the running service was loaded from.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-ccr-reload-'));
process.env.DEX_ROUTER_HOME = path.join(directory, 'router');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

const checkout = path.join(directory, 'checkout');
const copy = path.join(checkout, 'scripts', 'ccr');
fs.mkdirSync(copy, { recursive: true });
fs.mkdirSync(path.join(checkout, '.git'));
// Process identity and journal events run bin/router-runtime.sh from the checkout.
for (const name of ['bin', 'lib', 'scripts/dex_redact.py']) fs.symlinkSync(path.join(__dirname, '..', name), path.join(checkout, name));
for (const name of fs.readdirSync(path.join(__dirname, '..', 'scripts', 'ccr'))) {
  if (/\.(cjs|py)$/.test(name)) fs.copyFileSync(path.join(__dirname, '..', 'scripts', 'ccr', name), path.join(copy, name));
}
const state = require(path.join(copy, 'state.cjs'));
const ipc = require(path.join(copy, 'ipc.cjs'));
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
// A distinct mtime per edit, whatever the filesystem's timestamp resolution.
let edits = 0;
function edit(name, change) {
  const file = path.join(copy, name);
  fs.writeFileSync(file, change(fs.readFileSync(file, 'utf8')));
  const later = new Date(Date.now() + 5000 + ++edits * 1000);
  fs.utimesSync(file, later, later);
}
async function until(check, ms = 8000) {
  for (const end = Date.now() + ms; Date.now() < end; await wait(100)) if (await check()) return true;
  return false;
}

let server, stop, endpoint, release, tickets = [];
before(async () => {
  state.write(state.stateFile('config'), { version: 1, enabled: true, default_model: 'anthropic/test', phases: {}, models: [{ id: 'anthropic/test', provider: 'anthropic', context_window: 128000, capabilities: { tools: true } }] });
  state.saveAccounts([{ id: 'one', name: 'one', provider: 'anthropic', enabled: true, status: 'ready', created_at: 0 }]);
  state.saveBackend({ gateway: 'http://127.0.0.1:1', client_key: 'synthetic-local', management_key: 'synthetic-management' });
  // The upstream holds its stream open until the test releases it, so a
  // request is still running on the old code when the reload happens.
  const fetchImpl = async (_url, options) => {
    tickets.push(options.headers['x-ccr-dex-account-ticket']);
    const body = new ReadableStream({ start(controller) {
      controller.enqueue(new TextEncoder().encode('{"content":[{"type":"text","text":"answer"}]}'));
      release = () => controller.close();
    } });
    return new Response(body, { headers: { 'content-type': 'application/json' } });
  };
  const broker = { access: async () => ({ access_token: 'synthetic' }), usage: async () => ({ observed_at: Date.now(), windows: [] }) };
  const extension = require(path.join(copy, 'extension.cjs')).createExtension({ broker, fetchImpl });
  let handler;
  const ctx = { registerGatewayRoute: route => { handler = route.handler; }, registerCoreGatewayPlugin: () => {}, registerProviderAccountConnector: () => {} };
  ({ stop } = await extension.setup(ctx));
  server = http.createServer((request, response) => handler(request, response));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  endpoint = `http://127.0.0.1:${server.address().port}/plugins/dex/v1/messages`;
});
after(async () => {
  await stop();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(directory, { recursive: true, force: true });
});

test('a reload swaps the code without dropping the running request, its ticket or the socket', async () => {
  const token = state.token();
  await ipc.call('register', { id: 'reload', token, owner_pid: process.pid });
  const first = await ipc.call('health');
  assert.equal(first.reload_count, 0);
  const pending = fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify({ model: 'dex/active', messages: [{ role: 'user', content: 'hello' }] }) });
  assert.ok(await until(() => tickets.length === 1), 'the request reached the upstream');

  edit('service.cjs', source => source.replace("extension: 'dex-ccr',", "extension: 'dex-ccr', marker: 'second',"));
  const result = await ipc.call('reload');
  assert.equal(result.reloaded, true, result.last_reload_error);
  const health = await ipc.call('health');
  assert.equal(health.marker, 'second');
  assert.equal(health.reload_count, 1);
  assert.ok(health.started_at > first.started_at, 'started_at is when the serving code loaded');
  // The ticket the old code issued is still redeemable, and the answer names
  // the revision the core plugin should follow.
  const credential = await ipc.call('credential', { ticket: tickets[0], provider: 'anthropic' });
  assert.equal(credential.source_revision, health.source_revision);
  assert.equal(health.active_requests, 1, 'the old request is still counted');

  release();
  const response = await pending;
  assert.equal(response.status, 200);
  assert.match(await response.text(), /answer/);
  const events = fs.readFileSync(path.join(process.env.DEX_ROUTER_HOME, 'events.jsonl'), 'utf8');
  assert.match(events, /router\.reloaded/);
});

test('sources that do not load leave the previous code serving', async () => {
  edit('policy.cjs', source => `${source}\nfunction (`);
  const result = await ipc.call('reload');
  assert.equal(result.reloaded, false);
  assert.ok(result.last_reload_error);
  const health = await ipc.call('health');
  assert.equal(health.marker, 'second');
  assert.equal(health.reload_count, 1);
  assert.equal(health.last_reload_error, result.last_reload_error);
  edit('policy.cjs', source => source.replace(/\nfunction \($/, ''));
});

test('the watcher reloads settled edits and waits out a git operation', async () => {
  // The repair above is itself an edit, so the watcher reloads it.
  assert.ok(await until(async () => (await ipc.call('health')).reload_count === 2), 'the repaired sources were reloaded');
  assert.equal((await ipc.call('health')).last_reload_error, null);

  const lock = path.join(checkout, '.git', 'index.lock');
  fs.writeFileSync(lock, '');
  edit('service.cjs', source => source.replace("marker: 'second',", "marker: 'third',"));
  await wait(3500);
  assert.equal((await ipc.call('health')).marker, 'second', 'no reload while git holds its index lock');
  fs.rmSync(lock);
  assert.ok(await until(async () => (await ipc.call('health')).marker === 'third'));
});

test('a reload replaces the reload logic itself, and a shim edit is reported for restart', async () => {
  edit('host.cjs', source => source.replace("shim_changed: shimChanged(live) }", "shim_changed: shimChanged(live), host_marker: 'new' }"));
  const result = await ipc.call('reload');
  assert.equal(result.reloaded, true, result.last_reload_error);
  const health = await ipc.call('health');
  assert.equal(health.host_marker, 'new');
  assert.equal(health.shim_changed, false);
  edit('extension.cjs', source => `${source}\n// edited\n`);
  assert.ok(await until(async () => (await ipc.call('health')).shim_changed === true));
});
