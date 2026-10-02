'use strict';
// Performance workloads for long-refactor-inheritance, timed against the seed.

const path = require('node:path');

function lib(ws) {
  return require(path.join(ws, 'src', 'notifications'));
}

const USERS = {
  email: i => ({ id: `u${i}`, name: 'Ava', email: `u${i}@example.test`, emailOptIn: true }),
  sms: i => ({ id: `u${i}`, name: 'Bo', phone: '+15551234567', smsOptIn: true }),
  slack: i => ({ id: `u${i}`, slackId: `U${i}` }),
  inapp: i => ({ id: `u${i}`, name: 'Dee' })
};

module.exports.workloads = [
  {
    name: 'send 20k mixed notifications',
    setup: ws => {
      let t = Date.UTC(2026, 0, 1);
      const now = () => new Date(t);
      const options = { transport: {}, throttleStore: new Map(), now, maxPerHour: 1e6 };
      for (const channel of Object.keys(USERS)) {
        options.transport[channel] = async () => {};
      }
      const notifiers = Object.keys(USERS).map(channel => [channel, lib(ws).createNotifier(channel, options)]);
      return { notifiers, tick: () => { t += 1000; } };
    },
    run: async ({ notifiers, tick }) => {
      for (let i = 0; i < 20000; i++) {
        const [channel, n] = notifiers[i % notifiers.length];
        tick();
        // Sequential on purpose: each send reads the throttle state the last one wrote.
        await n.send(USERS[channel](i % 50), { title: 'Hi {{name}}', body: 'Update {{id}}', category: 'transactional' });
      }
    }
  },
  {
    name: 'createAllNotifiers x200k',
    setup: ws => ({ l: lib(ws) }),
    run: ({ l }) => {
      for (let i = 0; i < 200000; i++) {
        l.createAllNotifiers({ transport: {} });
      }
    }
  }
];
