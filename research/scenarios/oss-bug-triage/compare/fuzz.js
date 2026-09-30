'use strict';
// Differential fuzzing for oss-bug-triage: the agent's url-builder and the
// reference (the seed with the minimal ISSUE-214 fix) get the same random
// inputs, and every exported function must return the same thing or throw
// the same kind of error.
//
// The task says to fix one bug and change nothing else, so the reference is
// exact. The one choice the fix leaves open, whether an empty-string query
// value is kept or dropped, is never generated; nor is NaN.

const path = require('node:path');

const BASES = [
  'https://api.example.test',
  'https://api.example.test/',
  'https://api.example.test/v1',
  'https://api.example.test/v1/',
  'http://localhost:8080/base/',
  'https://api.example.test/x#frag',
  'https://api.example.test/p?existing=1',
  'ftp://files.example.test',
  'not a url'
];
const SEGMENTS = ['users', 'A B', 'a/b', ' x ', '', '%20', 'ümlaut', 'x%2Fy', '..', '100%', 0, 1, null, undefined, 'a?b', 'c#d'];
const KEYS = ['retry', 'include_archived', 'dry_run', 'limit', 'cursor', 'a', 'Z', 'tag', 'ids', 'q'];
const VALUES = ['abc', 'a b', 'ü', '&=?', '+', 0, 1, -1, 1.5, true, false, null, undefined, { nested: 1 }];
const URLS = [
  'https://app.example.test/login?next=%2Fhome&x=1&return_to=abc',
  'https://app.example.test/?redirect_uri=https%3A%2F%2Fevil.test&next=',
  'https://app.example.test/plain',
  'javascript:alert(1)',
  'not a url'
];

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

function value(rng) {
  if (rng() < 0.08) {
    return new Date(Date.UTC(2026, 1, 3, 4, 5, Math.floor(rng() * 60)));
  }
  if (rng() < 0.2) {
    return Array.from({ length: Math.floor(rng() * 4) }, () => pick(rng, VALUES));
  }
  return pick(rng, VALUES);
}

function options(rng) {
  const opts = { baseUrl: pick(rng, BASES) };
  const p = rng();
  if (p < 0.3) {
    opts.path = pick(rng, ['/a//b/', 'a/b c', 'x', '', 'users/42']);
  } else if (p < 0.85) {
    opts.path = Array.from({ length: Math.floor(rng() * 4) }, () => pick(rng, SEGMENTS));
  }
  const q = rng();
  if (q < 0.1) {
    opts.query = new URLSearchParams('b=2&a=1&a=0');
  } else if (q < 0.9) {
    opts.query = {};
    const n = Math.floor(rng() * 6);
    for (let i = 0; i < n; i++) {
      opts.query[pick(rng, KEYS)] = value(rng);
    }
  }
  if (rng() < 0.1) {
    opts.allowedProtocols = ['https:'];
  }
  return opts;
}

function generate(rng) {
  const r = rng();
  if (r < 0.6) {
    const opts = options(rng);
    return { fn: 'buildUrl', args: [opts] };
  }
  if (r < 0.8) {
    return { fn: 'buildSignedUrl', args: [options(rng), pick(rng, ['k', 'secret', ''])] };
  }
  if (r < 0.9) {
    return { fn: 'redactUrl', args: rng() < 0.5 ? [pick(rng, URLS)] : [pick(rng, URLS), ['x', 'next']] };
  }
  if (r < 0.95) {
    return { fn: 'isSafeRedirect', args: [pick(rng, URLS.concat(['https://api.example.test/ok', ''])), ['api.example.test', 'app.example.test']] };
  }
  return {
    fn: 'parseRetryAfter',
    args: [pick(rng, ['0', '120', '-5', '1.5', 'Wed, 21 Oct 2015 07:28:00 GMT', 'soon', '']), new Date('2026-01-02T03:04:05.000Z')]
  };
}

function observe(lib, op) {
  try {
    const out = lib[op.fn](...op.args);
    return { value: out instanceof Date ? out.toISOString() : out };
  } catch (err) {
    return { error: err && err.name };
  }
}

function describe(op) {
  return `${op.fn}(${op.args.map(a => (a instanceof URLSearchParams ? `URLSearchParams(${a})` : JSON.stringify(a))).join(', ')})`;
}

async function runSequence({ agentWs, refWs, rng, steps }) {
  const agent = require(path.join(agentWs, 'src', 'url-builder.js'));
  const ref = require(path.join(refWs, 'src', 'url-builder.js'));
  for (let step = 0; step < steps; step++) {
    const op = generate(rng);
    const want = observe(ref, op);
    const got = observe(agent, op);
    if (JSON.stringify(want) !== JSON.stringify(got)) {
      return { step, op: describe(op), expected: want, actual: got };
    }
  }
  return null;
}

module.exports = { runSequence };
