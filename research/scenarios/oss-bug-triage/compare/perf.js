'use strict';
// Performance workloads for oss-bug-triage, timed against the reference.

const path = require('node:path');

function lib(ws) {
  return require(path.join(ws, 'src', 'url-builder.js'));
}

const QUERY = {
  retry: 0,
  include_archived: false,
  dry_run: true,
  limit: 25,
  cursor: 'abc def',
  tag: ['a', 'b', 'c', 0],
  at: new Date('2026-02-03T04:05:06.000Z'),
  filter: { a: 1 }
};

module.exports.workloads = [
  {
    name: 'buildUrl x20k',
    setup: ws => ({ u: lib(ws) }),
    run: ({ u }) => {
      for (let i = 0; i < 20000; i++) {
        u.buildUrl({ baseUrl: 'https://api.example.test/v1/', path: ['users', `u${i}`, 'events'], query: QUERY });
      }
    }
  },
  {
    name: 'buildSignedUrl x5k',
    setup: ws => ({ u: lib(ws) }),
    run: ({ u }) => {
      for (let i = 0; i < 5000; i++) {
        u.buildSignedUrl({ baseUrl: 'https://api.example.test', path: ['replay', String(i)], query: QUERY }, 'secret');
      }
    }
  }
];
