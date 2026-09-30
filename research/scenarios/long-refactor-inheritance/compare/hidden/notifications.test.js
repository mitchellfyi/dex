'use strict';
// Hidden tests for long-refactor-inheritance. The agent never sees these.
//
// A refactor should change no observable behaviour, so every case here is
// [preserve]: the refactored library must return exactly what the seed
// returned (golden.json) for the same calls through the public factory API.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { CASES } = require('./_cases');
const GOLDEN = require('./golden.json');

function lib() {
  return require(path.join(process.env.BENCH_WS, 'src', 'notifications'));
}

for (const [name, run] of Object.entries(CASES)) {
  test(`[preserve] ${name}`, async () => {
    assert.ok(name in GOLDEN, `golden.json has no entry for "${name}"`);
    assert.deepEqual(await run(lib()), GOLDEN[name]);
  });
}
