const test = require('node:test');
const assert = require('node:assert/strict');
const { createNotifier, createAllNotifiers, registry } = require('../src/notifications');

function createTransport(log = []) {
  return {
    email: async payload => log.push(['email', payload]),
    sms: async payload => log.push(['sms', payload]),
    slack: async payload => log.push(['slack', payload]),
    inapp: async payload => log.push(['inapp', payload])
  };
}

test('factory creates every supported channel', () => {
  const notifiers = createAllNotifiers({ transport: createTransport() });

  assert.deepEqual(Object.keys(notifiers).sort(), ['email', 'inapp', 'slack', 'sms']);
  assert.equal(Object.keys(registry).length, 4);
});

test('factory rejects unknown channels', () => {
  assert.throws(() => createNotifier('fax'), /unknown notification channel/);
});

test('all channels return the same send result shape', async () => {
  const log = [];
  const transport = createTransport(log);
  const options = {
    transport,
    throttleStore: new Map(),
    now: () => new Date('2026-01-02T03:04:05.000Z')
  };
  const users = {
    email: { id: 'u1', name: 'Ava', email: 'ava@example.com', emailOptIn: true },
    sms: { id: 'u2', name: 'Bo', phone: '+15551234567', smsOptIn: true },
    slack: { id: 'u3', name: 'Cy', slackId: 'U123', slackWorkspace: 'eng' },
    inapp: { id: 'u4', name: 'Dee' }
  };
  const message = {
    title: 'Hello {{name}}',
    body: 'Your {{category}} update is ready',
    category: 'transactional'
  };

  for (const channel of Object.keys(users)) {
    const notifier = createNotifier(channel, options);
    const result = await notifier.send(users[channel], message);
    assert.equal(result.channel, channel);
    assert.equal(result.status, 'sent');
    assert.equal(result.userId, users[channel].id);
    assert.match(result.id, new RegExp(`^${channel}-`));
    assert.ok(result.preview.length > 0);
  }

  assert.deepEqual(log.map(entry => entry[0]).sort(), ['email', 'inapp', 'slack', 'sms']);
});

test('shared throttling applies per channel and category', async () => {
  const throttleStore = new Map();
  const notifier = createNotifier('sms', {
    transport: createTransport(),
    throttleStore,
    maxPerHour: 1,
    now: () => new Date('2026-01-02T03:04:05.000Z')
  });
  const user = { id: 'u1', phone: '+15551234567', smsOptIn: true };
  const message = { title: 'One', body: 'Two', category: 'general' };

  const first = await notifier.send(user, message);
  const second = await notifier.send(user, message);

  assert.equal(first.status, 'sent');
  assert.equal(second.status, 'throttled');
  assert.match(second.reason, /sms hourly limit/);
});
