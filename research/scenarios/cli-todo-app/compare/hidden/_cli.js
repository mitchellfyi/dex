'use strict';
// Shared helpers for the cli-todo-app hidden tests. They drive the CLI as a
// user would — `node index.js <command>` in a fresh directory — so any
// internal structure the agent chose works.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ENTRY = path.join(process.env.BENCH_WS, 'index.js');
const ANSI = /\u001b\[[0-9;]*[A-Za-z]/g;
// An uncaught exception prints frames like "    at fn (/path/file.js:12:5)".
const STACK = /^\s+at .*:\d+:\d+\)?$/m;

function freshDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'bench-todo-'));
}

function run(dir, ...args) {
  const result = spawnSync(process.execPath, [ENTRY, ...args], {
    cwd: dir,
    encoding: 'utf8',
    timeout: 20000,
    env: { ...process.env, NO_COLOR: '1', FORCE_COLOR: '0' }
  });
  const out = (result.stdout || '').replace(ANSI, '');
  const err = (result.stderr || '').replace(ANSI, '');
  return { code: result.status, out, err, all: `${out}\n${err}` };
}

function crashed(result) {
  return result.code === null || STACK.test(result.err) || STACK.test(result.out);
}

// The prompt fixes the file name and the fields, not the file's shape, so
// accept a bare array or an object holding the array.
function readTodos(dir) {
  const file = path.join(dir, 'todos.json');
  if (!fs.existsSync(file)) {
    return [];
  }
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (Array.isArray(data)) {
    return data;
  }
  if (data && typeof data === 'object') {
    for (const value of Object.values(data)) {
      if (Array.isArray(value)) {
        return value;
      }
    }
  }
  throw new Error('todos.json holds no array of todos');
}

function findLine(output, text) {
  return output.split('\n').find(line => line.includes(text));
}

module.exports = { freshDir, run, crashed, readTodos, findLine };
