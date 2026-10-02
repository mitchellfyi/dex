'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { releaseLock } = require('../hooks/release-lock');

test('allows the lock owner to release its lock', (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-lock-visible-'));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const lockPath = path.join(directory, 'worker.lock');
  fs.writeFileSync(lockPath, 'owner-a');

  assert.equal(releaseLock(lockPath, 'owner-a'), true);
  assert.equal(fs.existsSync(lockPath), false);
});

test('reports a missing lock without throwing', () => {
  assert.equal(releaseLock('/path/that/does/not/exist/dex.lock', 'owner-a'), false);
});
