'use strict';
// Characterization cases for the notification library. Each case drives the
// public factory API only and returns everything a caller could observe: the
// send results (or errors, and whether they were thrown or rejected) and every
// payload handed to the transport.
//
// golden.json holds what the seed returns for each case. Regenerate it with
// `node _generate-golden.js <seed-dir>` after changing a case.

const NOW = '2026-01-02T03:04:05.000Z';
const HOUR = 60 * 60 * 1000;

function clock(start = NOW) {
  let t = new Date(start).getTime();
  const now = () => new Date(t);
  now.advance = ms => {
    t += ms;
  };
  return now;
}

function makeTransport(log, channels = ['email', 'sms', 'slack', 'inapp', 'webhook']) {
  const transport = {};
  for (const channel of channels) {
    transport[channel] = async payload => {
      log.push([channel, JSON.parse(JSON.stringify(payload))]);
    };
  }
  return transport;
}

function errorInfo(err) {
  return { name: err && err.name, message: err && err.message };
}

// Distinguish a synchronous throw from a rejected promise: callers written
// against the seed use `await` or `.catch`, and a refactor that starts
// throwing synchronously breaks the second kind.
function call(fn) {
  let pending;
  try {
    pending = fn();
  } catch (err) {
    return Promise.resolve({ threw: 'sync', error: errorInfo(err) });
  }
  const promise = !!pending && typeof pending.then === 'function';
  return Promise.resolve(pending).then(
    value => ({ promise, value: JSON.parse(JSON.stringify(value === undefined ? null : value)) }),
    err => ({ threw: 'async', error: errorInfo(err) })
  );
}

async function session(lib, channel, opts, steps) {
  const log = [];
  const now = clock();
  const notifier = lib.createNotifier(channel, {
    transport: makeTransport(log),
    throttleStore: new Map(),
    now,
    ...opts
  });
  const results = [];
  for (const step of steps) {
    if (step.advance) {
      now.advance(step.advance);
      continue;
    }
    results.push(await call(() => notifier.send(step.user, step.message, step.options)));
  }
  return { results, log };
}

const USERS = {
  email: { id: 'u1', name: 'Ava', email: 'ava@example.com', emailOptIn: true },
  sms: { id: 'u2', name: 'Bo', phone: '+15551234567', smsOptIn: true },
  slack: { id: 'u3', name: 'Cy', slackId: 'U123', slackWorkspace: 'eng' },
  inapp: { id: 'u4', name: 'Dee' }
};

const MSG = {
  title: 'Hello {{name}}',
  body: 'Your {{category}} update for {{id}}',
  category: 'transactional'
};

function repeat(n, step) {
  return Array.from({ length: n }, () => step);
}

const CASES = {
  'email transactional': lib => session(lib, 'email', {}, [{ user: USERS.email, message: MSG }]),

  'email security': lib =>
    session(lib, 'email', {}, [{ user: USERS.email, message: { ...MSG, category: 'security' } }]),

  'email marketing without opt-in': lib =>
    session(lib, 'email', {}, [
      { user: { ...USERS.email, emailOptIn: false }, message: { ...MSG, category: 'marketing' } }
    ]),

  'email marketing footer': lib =>
    session(lib, 'email', {}, [
      { user: { id: 'u 1/2', email: 'x@y.z', emailOptIn: true }, message: { ...MSG, category: 'marketing' } }
    ]),

  'email html escaping': lib =>
    session(lib, 'email', {}, [
      { user: USERS.email, message: { title: `<b>"Tom" & 'Jerry'</b>`, body: '1 < 2 > 0' } }
    ]),

  'email invalid address': lib =>
    session(lib, 'email', {}, [{ user: { id: 'u1', email: 'nope' }, message: MSG }]),

  'email custom sender options': lib =>
    session(
      lib,
      'email',
      { from: 'a@b.test', replyTo: 'r@b.test', unsubscribeBaseUrl: 'https://u.test/off', defaultLocale: 'fr-FR' },
      [{ user: USERS.email, message: { title: 'T', body: 'B' } }]
    ),

  'email default hourly limit': lib =>
    session(lib, 'email', {}, [
      ...repeat(9, { user: USERS.email, message: { title: 'T', body: 'B' } }),
      { advance: HOUR },
      { user: USERS.email, message: { title: 'T', body: 'B' } }
    ]),

  'sms urgent prefix and bypass': lib =>
    session(lib, 'sms', { maxPerHour: 1 }, repeat(3, { user: USERS.sms, message: { ...MSG, priority: 'urgent' } })),

  'sms truncation': lib =>
    session(lib, 'sms', {}, [{ user: USERS.sms, message: { title: 'Long', body: 'x'.repeat(200) } }]),

  'sms custom segment length': lib =>
    session(lib, 'sms', { segmentLength: 20, senderId: 'ACME' }, [
      { user: USERS.sms, message: { title: 'Short', body: 'y'.repeat(30) } }
    ]),

  'sms invalid phone': lib => session(lib, 'sms', {}, [{ user: { id: 'u2', phone: '5551234' }, message: MSG }]),

  'sms marketing without opt-in': lib =>
    session(lib, 'sms', {}, [
      { user: { ...USERS.sms, smsOptIn: false }, message: { ...MSG, category: 'marketing' } }
    ]),

  'slack channel precedence': lib =>
    session(lib, 'slack', { defaultWorkspace: 'hq', defaultChannel: '#news' }, [
      { user: { id: 'u5', slackId: 'U5' }, message: MSG },
      { user: { id: 'u5', slackId: 'U5', slackChannel: '#team' }, message: MSG },
      { user: { id: 'u5', slackId: 'U5', slackChannel: '#team' }, message: MSG, options: { channel: '#override' } }
    ]),

  'slack thread replies bypass throttling': lib =>
    session(lib, 'slack', { maxPerHour: 1 }, [
      ...repeat(3, { user: USERS.slack, message: MSG, options: { threadTs: '123.45' } }),
      ...repeat(2, { user: USERS.slack, message: MSG })
    ]),

  'slack channel-only user': lib =>
    session(lib, 'slack', {}, [{ user: { id: 'u9', slackChannel: '#ops' }, message: MSG }]),

  'slack missing destination': lib => session(lib, 'slack', {}, [{ user: { id: 'u9' }, message: MSG }]),

  'inapp expiry and metadata': lib =>
    session(lib, 'inapp', { defaultIcon: 'dot' }, [
      { user: USERS.inapp, message: MSG },
      { user: USERS.inapp, message: { ...MSG, priority: 'urgent' } },
      {
        user: USERS.inapp,
        message: { ...MSG, icon: 'star', actionUrl: '/m' },
        options: { expiresInHours: 2, actionUrl: '/x' }
      },
      { user: USERS.inapp, message: { ...MSG, actionUrl: '/m' } }
    ]),

  'inapp security bypasses throttling': lib =>
    session(lib, 'inapp', { maxPerHour: 1 }, repeat(3, { user: USERS.inapp, message: { ...MSG, category: 'security' } })),

  'inapp disabled user': lib =>
    session(lib, 'inapp', {}, [{ user: { id: 'u4', disabledInApp: true }, message: MSG }]),

  'templates and locale': async lib => ({
    email: await session(lib, 'email', {}, [
      { user: { id: 'u7', email: 'n@n.test', locale: 'de-DE' }, message: { title: '{{name}} {{id}}', body: '{{category}}' } },
      { user: { id: 'u7', email: 'n@n.test', locale: 'de-DE' }, message: { title: 'a', body: 'b' }, options: { locale: 'es-ES' } }
    ]),
    sms: await session(lib, 'sms', { defaultLocale: 'pt-BR' }, [{ user: USERS.sms, message: MSG }])
  }),

  'validation errors': async lib => {
    const out = {};
    for (const channel of Object.keys(USERS)) {
      out[channel] = await session(lib, channel, {}, [
        { user: null, message: MSG },
        { user: {}, message: MSG },
        { user: USERS[channel], message: null },
        { user: USERS[channel], message: { title: 't' } },
        { user: USERS[channel], message: { body: 'b' } }
      ]);
    }
    return out;
  },

  'missing transport': async lib => {
    const out = {};
    for (const channel of Object.keys(USERS)) {
      out[channel] = await session(lib, channel, { transport: {} }, [{ user: USERS[channel], message: MSG }]);
    }
    return out;
  },

  'force bypasses throttling': lib =>
    session(lib, 'sms', { maxPerHour: 1 }, repeat(2, { user: USERS.sms, message: MSG, options: { force: true } })),

  'throttle window per category': lib => {
    const a = { user: USERS.sms, message: { title: 'A', body: 'a', category: 'alpha' } };
    const b = { user: USERS.sms, message: { title: 'B', body: 'b', category: 'beta' } };
    return session(lib, 'sms', { maxPerHour: 1 }, [
      a,
      a,
      b,
      { advance: 59 * 60 * 1000 },
      a,
      { advance: 2 * 60 * 1000 },
      a
    ]);
  },

  'failed delivery is not recorded': async lib => {
    const log = [];
    let calls = 0;
    const notifier = lib.createNotifier('sms', {
      maxPerHour: 1,
      throttleStore: new Map(),
      now: clock(),
      transport: {
        sms: async payload => {
          calls += 1;
          if (calls === 1) {
            throw new Error('gateway down');
          }
          log.push(['sms', JSON.parse(JSON.stringify(payload))]);
        }
      }
    });
    const results = [];
    for (let i = 0; i < 3; i++) {
      results.push(await call(() => notifier.send(USERS.sms, MSG)));
    }
    return { results, log, calls };
  },

  'shared throttle store': async lib => {
    const log = [];
    const throttleStore = new Map();
    const now = clock();
    const options = { transport: makeTransport(log), throttleStore, now, maxPerHour: 1 };
    const first = lib.createNotifier('sms', options);
    const second = lib.createNotifier('sms', options);
    const email = lib.createNotifier('email', options);
    const user = { ...USERS.sms, email: 'bo@example.com' };
    return {
      results: [
        await call(() => first.send(user, MSG)),
        await call(() => second.send(user, MSG)),
        await call(() => email.send(user, MSG))
      ],
      log
    };
  },

  factory: async lib => {
    const log = [];
    const all = lib.createAllNotifiers({ transport: makeTransport(log), throttleStore: new Map(), now: clock(), maxPerHour: 1 });
    const known = ['email', 'inapp', 'slack', 'sms'];
    return {
      hasAllChannels: known.every(channel => all[channel] && typeof all[channel].send === 'function'),
      registryHasAllChannels: known.every(channel => Object.keys(lib.registry).includes(channel)),
      sends: [
        await call(() => all.email.send(USERS.email, MSG)),
        await call(() => all.email.send(USERS.email, MSG)),
        await call(() => all.sms.send(USERS.sms, MSG))
      ],
      unknown: await call(() => lib.createNotifier('fax')),
      missing: await call(() => lib.createNotifier()),
      log
    };
  }
};

module.exports = { CASES, NOW, HOUR, clock, makeTransport, call, session, USERS, MSG };
