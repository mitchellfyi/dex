const test = require('node:test');
const assert = require('node:assert/strict');
const { createNotifier } = require('../src/notifications');

function transportWithLog(log) {
  return {
    email: async payload => log.push(payload),
    sms: async payload => log.push(payload),
    slack: async payload => log.push(payload),
    inapp: async payload => log.push(payload)
  };
}

test('email formats subject, html, text footer, and opt-out behavior', async () => {
  const log = [];
  const notifier = createNotifier('email', {
    transport: transportWithLog(log),
    throttleStore: new Map(),
    from: 'alerts@example.com',
    replyTo: 'help@example.com'
  });

  const user = { id: 'u1', name: 'Ava', email: 'ava@example.com', emailOptIn: false };
  const marketing = await notifier.send(user, { title: 'Deal', body: 'Save now', category: 'marketing' });
  assert.equal(marketing.status, 'throttled');
  assert.match(marketing.reason, /not opted/);

  const sent = await notifier.send(user, { title: 'Login', body: '<script>', category: 'security' });
  assert.equal(sent.status, 'sent');
  assert.equal(log[0].to, 'ava@example.com');
  assert.equal(log[0].from, 'alerts@example.com');
  assert.match(log[0].subject, /^\[Action Required\] Login/);
  assert.match(log[0].html, /&lt;script&gt;/);
  assert.match(log[0].text, /recent account activity/);
});

test('SMS validates phone numbers and truncates long urgent messages', async () => {
  const log = [];
  const notifier = createNotifier('sms', {
    transport: transportWithLog(log),
    throttleStore: new Map(),
    segmentLength: 40
  });

  await assert.rejects(
    () => notifier.send({ id: 'bad', phone: '555-1212' }, { title: 'T', body: 'B' }),
    /E\.164/
  );

  const result = await notifier.send(
    { id: 'u2', phone: '+15551234567', smsOptIn: true },
    { title: 'A'.repeat(20), body: 'B'.repeat(40), priority: 'urgent', category: 'transactional' }
  );

  assert.equal(result.status, 'sent');
  assert.equal(log[0].text.length, 40);
  assert.match(log[0].text, /^URGENT:/);
  assert.equal(log[0].segments, 1);
});

test('Slack formats mentions, channel overrides, blocks, and thread replies', async () => {
  const log = [];
  const notifier = createNotifier('slack', {
    transport: transportWithLog(log),
    throttleStore: new Map(),
    defaultWorkspace: 'product'
  });

  const result = await notifier.send(
    { id: 'u3', slackId: 'U123', slackChannel: '#alerts' },
    { title: 'Deploy', body: 'Finished', category: 'release' },
    { channel: '#ops', threadTs: '171234.0001' }
  );

  assert.equal(result.status, 'sent');
  assert.equal(log[0].workspace, 'product');
  assert.equal(log[0].channel, '#ops');
  assert.equal(log[0].threadTs, '171234.0001');
  assert.match(log[0].text, /<@U123>/);
  assert.equal(log[0].blocks.length, 3);
});

test('in-app notifications include action metadata and security messages bypass throttling', async () => {
  const log = [];
  const notifier = createNotifier('inapp', {
    transport: transportWithLog(log),
    throttleStore: new Map(),
    maxPerHour: 1,
    now: () => new Date('2026-01-02T00:00:00.000Z')
  });
  const user = { id: 'u4', name: 'Dee' };
  const message = { title: 'Password changed', body: 'Review activity', category: 'security' };

  const first = await notifier.send(user, message, { actionUrl: '/security' });
  const second = await notifier.send(user, message, { actionUrl: '/security' });

  assert.equal(first.status, 'sent');
  assert.equal(second.status, 'sent');
  assert.equal(log[0].userId, 'u4');
  assert.equal(log[0].read, false);
  assert.equal(log[0].actionUrl, '/security');
  assert.equal(log[0].expiresAt, '2026-01-09T00:00:00.000Z');
});
