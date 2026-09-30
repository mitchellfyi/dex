'use strict';
// Differential fuzzing for cli-todo-app: the agent's CLI and the reference CLI
// run the same random command sequences, each in its own empty directory.
//
// After every command the two stores must hold the same todos (text and
// completed flag, in id order), and neither CLI may crash. Ids are not
// compared: a command that targets "the second todo" is sent with whatever id
// each CLI gave it, so id-numbering policy is not a divergence. How an error
// is reported (exit code or message) is measured separately, not here.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const STACK = /^\s+at .*:\d+:\d+\)?$/m;
const TEXTS = ['milk', 'Buy eggs', 'Café ✓', 'say "hi"', "it's", 'a  b', '100%', 'tab\there', 'semi;colon', '$HOME', 'back\\slash', '日本語'];

function cli(ws, dir, args) {
  const r = spawnSync(process.execPath, [path.join(ws, 'index.js'), ...args], {
    cwd: dir,
    encoding: 'utf8',
    timeout: 20000,
    env: { ...process.env, NO_COLOR: '1', FORCE_COLOR: '0' }
  });
  return { code: r.status, out: r.stdout || '', err: r.stderr || '' };
}

function todos(dir) {
  const file = path.join(dir, 'todos.json');
  if (!fs.existsSync(file)) {
    return [];
  }
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_err) {
    return 'unreadable todos.json';
  }
  let list = Array.isArray(data) ? data : null;
  if (!list && data && typeof data === 'object') {
    list = Object.values(data).find(Array.isArray) || null;
  }
  if (!list) {
    return 'todos.json holds no array';
  }
  return [...list].sort((a, b) => a.id - b.id);
}

function normalize(list) {
  return typeof list === 'string' ? list : list.map(t => [t.text, !!t.completed]);
}

function pick(rng, items) {
  return items[Math.floor(rng() * items.length)];
}

// Build one command for both CLIs. `target` is a position in the reference
// store; each CLI gets the id it gave the todo at that position.
function generate(rng, count) {
  const r = rng();
  if (r < 0.35 || count === 0) {
    return { name: 'add', args: [pick(rng, TEXTS)] };
  }
  if (r < 0.4) {
    return { name: 'add (no text)', args: ['add'] };
  }
  if (r < 0.55) {
    return { name: 'list', args: ['list'] };
  }
  if (r < 0.7) {
    return { name: 'complete', command: 'complete', target: Math.floor(rng() * count) };
  }
  if (r < 0.82) {
    return { name: 'delete', command: 'delete', target: Math.floor(rng() * count) };
  }
  if (r < 0.9) {
    return { name: 'unknown id', command: pick(rng, ['complete', 'delete']), missing: true };
  }
  if (r < 0.95) {
    return { name: 'non-numeric id', args: [pick(rng, ['complete', 'delete']), 'abc'] };
  }
  return { name: 'missing id', args: [pick(rng, ['complete', 'delete'])] };
}

function argsFor(op, list) {
  if (op.name === 'add') {
    return ['add', ...op.args];
  }
  if (op.args) {
    return op.args;
  }
  if (op.missing) {
    const maxId = list.reduce((m, t) => Math.max(m, t.id), 0);
    return [op.command, String(maxId + 50)];
  }
  return [op.command, String(list[op.target].id)];
}

async function runSequence({ agentWs, refWs, rng, steps }) {
  const dirs = {
    agent: fs.mkdtempSync(path.join(os.tmpdir(), 'bench-fuzz-a-')),
    ref: fs.mkdtempSync(path.join(os.tmpdir(), 'bench-fuzz-r-'))
  };
  const history = [];
  try {
    for (let step = 0; step < steps; step++) {
      const refList = todos(dirs.ref);
      const agentList = todos(dirs.agent);
      if (typeof agentList === 'string') {
        return { step, op: 'read store', expected: normalize(refList), actual: agentList, history };
      }
      const op = generate(rng, refList.length);
      const refArgs = argsFor(op, refList);
      const agentArgs = argsFor(op, agentList);
      history.push(agentArgs.join(' '));
      const refRun = cli(refWs, dirs.ref, refArgs);
      const agentRun = cli(agentWs, dirs.agent, agentArgs);
      if (STACK.test(refRun.err)) {
        throw Object.assign(new Error(`reference crashed on ${refArgs.join(' ')}`), { harness: true });
      }
      if (agentRun.code === null || STACK.test(agentRun.err) || STACK.test(agentRun.out)) {
        return { step, op: agentArgs.join(' '), actual: 'crashed', stderr: agentRun.err.slice(-400), history };
      }
      const want = normalize(todos(dirs.ref));
      const got = normalize(todos(dirs.agent));
      if (JSON.stringify(want) !== JSON.stringify(got)) {
        return { step, op: agentArgs.join(' '), expected: want, actual: got, history };
      }
      if (op.name === 'list') {
        if (agentRun.code !== 0) {
          return { step, op: 'list', actual: `exit ${agentRun.code}`, history };
        }
        const missing = want.map(([text]) => text).filter(text => !agentRun.out.includes(text));
        if (missing.length) {
          return { step, op: 'list', actual: `list output is missing ${JSON.stringify(missing)}`, history };
        }
      }
    }
    return null;
  } finally {
    fs.rmSync(dirs.agent, { recursive: true, force: true });
    fs.rmSync(dirs.ref, { recursive: true, force: true });
  }
}

module.exports = { runSequence };
