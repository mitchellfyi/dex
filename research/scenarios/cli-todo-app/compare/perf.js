'use strict';
// Performance workloads for cli-todo-app. Each run starts the CLI as a user
// would, so node startup and whatever the CLI loads at startup count.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function cli(ws, dir, args) {
  const r = spawnSync(process.execPath, [path.join(ws, 'index.js'), ...args], {
    cwd: dir,
    encoding: 'utf8',
    timeout: 30000,
    env: { ...process.env, NO_COLOR: '1', FORCE_COLOR: '0' }
  });
  if (r.status !== 0) {
    throw new Error(`${args.join(' ')} exited ${r.status}: ${(r.stderr || '').slice(-200)}`);
  }
}

// Write 1000 todos in whatever shape this CLI stores them: add one todo
// through the CLI, read the file back, and repeat its shape.
function seedStore(ws, dir, count) {
  cli(ws, dir, ['add', 'template']);
  const file = path.join(dir, 'todos.json');
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  const list = Array.isArray(data) ? data : Object.values(data).find(Array.isArray);
  const template = list[0];
  const todos = Array.from({ length: count }, (_, i) => ({
    ...template,
    id: i + 1,
    text: `todo number ${i + 1}`,
    completed: i % 3 === 0,
    createdAt: new Date(Date.UTC(2026, 0, 1, 0, 0, i)).toISOString()
  }));
  let out;
  if (Array.isArray(data)) {
    out = todos;
  } else {
    out = { ...data };
    for (const [key, value] of Object.entries(data)) {
      if (Array.isArray(value)) {
        out[key] = todos;
      } else if (typeof value === 'number') {
        out[key] = count + 1;
      }
    }
  }
  fs.writeFileSync(file, JSON.stringify(out));
}

function freshDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'bench-perf-todo-'));
}

module.exports.workloads = [
  {
    name: 'list with 1000 todos',
    kind: 'cli',
    setup: ws => {
      const dir = freshDir();
      seedStore(ws, dir, 1000);
      return { ws, dir };
    },
    run: ({ ws, dir }) => {
      for (let i = 0; i < 3; i++) {
        cli(ws, dir, ['list']);
      }
    }
  },
  {
    name: '20 sequential adds',
    kind: 'cli',
    setup: ws => ({ ws, dir: freshDir() }),
    run: ({ ws, dir }) => {
      for (let i = 0; i < 20; i++) {
        cli(ws, dir, ['add', `task ${i}`]);
      }
    }
  },
  {
    name: 'complete in a 1000-todo store',
    kind: 'cli',
    setup: ws => {
      const dir = freshDir();
      seedStore(ws, dir, 1000);
      return { ws, dir };
    },
    run: ({ ws, dir }) => {
      for (const id of [2, 500, 999]) {
        cli(ws, dir, ['complete', String(id)]);
      }
    }
  }
];
