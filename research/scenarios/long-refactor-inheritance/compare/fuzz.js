'use strict';
// Differential fuzzing for long-refactor-inheritance: the refactored library
// and the seed get the same random sends, clock moves and factory calls, and
// every observable result must match exactly. A refactor promises identical
// behaviour, so the seed is the oracle for everything, including results,
// error names and messages, throttling, and every payload the transport sees.

const path = require('node:path');
const { clock, makeTransport, call } = require('./hidden/_cases');

const CHANNELS = ['email', 'sms', 'slack', 'inapp'];
const MINUTE = 60 * 1000;

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

function maybe(rng, p, value) {
  return rng() < p ? value : undefined;
}

function user(rng, channel) {
  const id = pick(rng, ['u1', 'u2', 'u 3/x', 'u4']);
  const base = { id, name: maybe(rng, 0.7, pick(rng, ['Ava', 'Bo', 'Ümit'])), locale: maybe(rng, 0.2, 'de-DE') };
  const broken = rng() < 0.12;
  switch (channel) {
    case 'email':
      return { ...base, email: broken ? 'nope' : `${id.replace(/\W/g, '')}@example.test`, emailOptIn: rng() < 0.5 };
    case 'sms':
      return { ...base, phone: broken ? '5551234' : pick(rng, ['+15551234567', '+447700900123']), smsOptIn: rng() < 0.5 };
    case 'slack':
      return broken ? base : { ...base, slackId: maybe(rng, 0.7, 'U123'), slackChannel: maybe(rng, 0.5, '#team'), slackWorkspace: maybe(rng, 0.3, 'eng') };
    default:
      return { ...base, disabledInApp: broken };
  }
}

function message(rng) {
  if (rng() < 0.06) {
    return pick(rng, [null, { title: 'only title' }, { body: 'only body' }]);
  }
  return {
    title: pick(rng, ['Hello {{name}}', 'Alert', '{{id}} / {{category}}', '<b>x</b> & "y"', 'T'.repeat(130)]),
    body: pick(rng, ['Body for {{id}}', 'short', 'x'.repeat(200), '{{name}} {{name}}']),
    category: pick(rng, [undefined, 'general', 'marketing', 'security', 'transactional']),
    priority: pick(rng, [undefined, 'urgent', 'normal']),
    icon: maybe(rng, 0.1, 'star'),
    actionUrl: maybe(rng, 0.1, '/m')
  };
}

function sendOptions(rng) {
  return pick(rng, [
    undefined,
    {},
    { force: true },
    { threadTs: '1.2' },
    { channel: '#override' },
    { locale: 'es-ES' },
    { expiresInHours: 1 + Math.floor(rng() * 100) },
    { actionUrl: '/x' }
  ]);
}

function notifierOptions(rng) {
  return {
    maxPerHour: pick(rng, [undefined, 1, 2, 3]),
    from: maybe(rng, 0.2, 'a@b.test'),
    senderId: maybe(rng, 0.2, 'ACME'),
    segmentLength: maybe(rng, 0.2, pick(rng, [20, 60])),
    defaultChannel: maybe(rng, 0.2, '#news'),
    defaultIcon: maybe(rng, 0.2, 'dot'),
    defaultLocale: maybe(rng, 0.2, 'fr-FR')
  };
}

// One implementation's world: its notifiers, one shared throttle store, a
// clock and a transport log.
function world(lib, opts) {
  const log = [];
  const now = clock();
  const shared = { ...opts, transport: makeTransport(log), throttleStore: new Map(), now };
  const notifiers = {};
  for (const channel of CHANNELS) {
    notifiers[channel] = lib.createNotifier(channel, shared);
  }
  return { lib, log, now, notifiers, shared };
}

async function runSequence({ agentWs, refWs, rng, steps }) {
  const agentLib = require(path.join(agentWs, 'src', 'notifications'));
  const refLib = require(path.join(refWs, 'src', 'notifications'));
  const opts = notifierOptions(rng);
  const worlds = { agent: world(agentLib, opts), ref: world(refLib, opts) };
  const history = [];
  for (let step = 0; step < steps; step++) {
    const r = rng();
    if (r < 0.2) {
      const ms = (1 + Math.floor(rng() * 90)) * MINUTE;
      worlds.agent.now.advance(ms);
      worlds.ref.now.advance(ms);
      history.push(`advance ${ms / MINUTE}m`);
      continue;
    }
    let op;
    const observed = {};
    if (r < 0.93) {
      const channel = pick(rng, CHANNELS);
      const u = user(rng, channel);
      const m = message(rng);
      const o = sendOptions(rng);
      op = `${channel}.send(${JSON.stringify(u)}, ${JSON.stringify(m)}, ${JSON.stringify(o)})`;
      for (const who of ['agent', 'ref']) {
        const w = worlds[who];
        const before = w.log.length;
        // Sequential on purpose: each send changes the throttle state the next reads.
        const result = await call(() => w.notifiers[channel].send(u, m, o));
        observed[who] = { result, delivered: w.log.slice(before) };
      }
    } else {
      const channel = pick(rng, ['email', 'fax', undefined]);
      op = `createNotifier(${JSON.stringify(channel)}) and createAllNotifiers()`;
      for (const who of ['agent', 'ref']) {
        const w = worlds[who];
        const created = await call(() => {
          const n = w.lib.createNotifier(channel, w.shared);
          return typeof n.send;
        });
        const all = Object.keys(w.lib.createAllNotifiers(w.shared)).filter(k => CHANNELS.includes(k)).sort();
        observed[who] = { created, all };
      }
    }
    history.push(op);
    if (JSON.stringify(observed.agent) !== JSON.stringify(observed.ref)) {
      return { step, op, expected: observed.ref, actual: observed.agent, history: history.slice(-8) };
    }
  }
  return null;
}

module.exports = { runSequence };
