'use strict';
// Hidden tests for the long-refactor-inheritance follow-up task (webhook).
// measure.py stages these beside the main hidden suite, so `_cases` is shared.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { clock, makeTransport, call, MSG } = require('./_cases');

function lib() {
  return require(path.join(process.env.BENCH_WS, 'src', 'notifications'));
}

const USER = { id: 'w1', name: 'Wes', webhookUrl: 'https://hooks.example.test/in' };

function notifier(opts = {}) {
  const log = [];
  const n = lib().createNotifier('webhook', {
    transport: makeTransport(log),
    throttleStore: new Map(),
    now: clock(),
    ...opts
  });
  return { n, log };
}

test('[followup] the factory creates webhook notifiers', () => {
  const all = lib().createAllNotifiers({ transport: makeTransport([]) });
  assert.equal(typeof all.webhook.send, 'function');
  assert.deepEqual(Object.keys(all).sort(), ['email', 'inapp', 'slack', 'sms', 'webhook']);
});

test('[followup] a webhook send returns the shared result shape', async () => {
  const { n } = notifier();
  const result = await n.send(USER, MSG);
  assert.equal(result.channel, 'webhook');
  assert.equal(result.status, 'sent');
  assert.equal(result.userId, 'w1');
  assert.equal(result.id, 'webhook-w1-1767323045000');
  assert.equal(result.preview, 'Hello Wes: Your transactional update for w1');
});

test('[followup] the webhook payload carries the shared fields and the request', async () => {
  const { n, log } = notifier();
  await n.send(USER, { title: 'Hi {{name}}', body: 'Body for {{id}}' });
  assert.equal(log.length, 1);
  const [channel, payload] = log[0];
  assert.equal(channel, 'webhook');
  const { json, ...rest } = payload;
  assert.deepEqual(rest, {
    id: 'webhook-w1-1767323045000',
    channel: 'webhook',
    locale: 'en-US',
    title: 'Hi Wes',
    body: 'Body for w1',
    preview: 'Hi Wes: Body for w1',
    metadata: { category: 'general', priority: 'normal', generatedAt: '2026-01-02T03:04:05.000Z' },
    url: 'https://hooks.example.test/in',
    method: 'POST',
    headers: { 'content-type': 'application/json' }
  });
  assert.equal(typeof json, 'string');
  assert.deepEqual(JSON.parse(json), { title: 'Hi Wes', body: 'Body for w1', category: 'general', userId: 'w1' });
});

test('[followup] a missing or non-https webhookUrl is rejected', async () => {
  const { n, log } = notifier();
  for (const user of [{ id: 'w1' }, { id: 'w1', webhookUrl: 'http://insecure.test' }]) {
    const outcome = await call(() => n.send(user, MSG));
    assert.equal(outcome.threw, 'async', JSON.stringify(outcome));
    assert.equal(outcome.error.name, 'TypeError');
    assert.match(outcome.error.message, /webhookUrl/);
  }
  assert.equal(log.length, 0);
});

test('[followup] the default hourly limit is 10', async () => {
  const { n } = notifier();
  const statuses = [];
  for (let i = 0; i < 11; i++) {
    // Sequential on purpose: each send counts toward the next one's limit.
    statuses.push((await n.send(USER, MSG)).status);
  }
  assert.deepEqual(statuses, [...Array(10).fill('sent'), 'throttled']);
});

test('[followup] maxPerHour overrides the webhook limit', async () => {
  const { n } = notifier({ maxPerHour: 1 });
  assert.equal((await n.send(USER, MSG)).status, 'sent');
  const second = await n.send(USER, MSG);
  assert.equal(second.status, 'throttled');
  assert.match(second.reason, /webhook hourly limit/);
});

test('[followup] a missing webhook transport rejects', async () => {
  const { n } = notifier({ transport: {} });
  const outcome = await call(() => n.send(USER, MSG));
  assert.equal(outcome.threw, 'async');
  assert.equal(outcome.error.message, 'webhook transport is not configured');
});

test('[followup] shared validation and urgent bypass apply', async () => {
  const { n } = notifier({ maxPerHour: 1 });
  const invalid = await call(() => n.send({ webhookUrl: USER.webhookUrl }, MSG));
  assert.equal(invalid.error && invalid.error.message, 'user.id is required');
  const results = [];
  for (let i = 0; i < 3; i++) {
    results.push((await n.send(USER, { ...MSG, priority: 'urgent' })).status);
  }
  assert.deepEqual(results, ['sent', 'sent', 'sent']);
});
