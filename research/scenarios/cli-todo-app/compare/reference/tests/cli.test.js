const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ENTRY = path.join(__dirname, '..', 'index.js');

function cli(dir, ...args) {
  return spawnSync(process.execPath, [ENTRY, ...args], { cwd: dir, encoding: 'utf8' });
}

function dir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'todo-test-'));
}

test('add, list, complete, delete', () => {
  const d = dir();
  assert.equal(cli(d, 'add', 'milk').status, 0);
  assert.equal(cli(d, 'add', 'eggs').status, 0);
  assert.match(cli(d, 'list').stdout, /1\. \[ \] milk/);
  assert.equal(cli(d, 'complete', '1').status, 0);
  assert.match(cli(d, 'list').stdout, /1\. \[x\] milk/);
  assert.equal(cli(d, 'delete', '2').status, 0);
  assert.doesNotMatch(cli(d, 'list').stdout, /eggs/);
});

test('errors exit non-zero', () => {
  const d = dir();
  assert.equal(cli(d, 'add').status, 1);
  assert.equal(cli(d, 'complete', '5').status, 1);
  assert.equal(cli(d, 'delete', 'x').status, 1);
  assert.equal(cli(d, 'nope').status, 1);
});

test('empty list', () => {
  assert.match(cli(dir(), 'list').stdout, /No todos/);
});
