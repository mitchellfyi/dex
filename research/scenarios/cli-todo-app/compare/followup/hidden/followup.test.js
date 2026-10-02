'use strict';
// Hidden tests for the cli-todo-app follow-up task (edit, list --pending).
// measure.py stages these beside the main hidden suite, so `_cli` is shared.

const test = require('node:test');
const assert = require('node:assert/strict');

const { freshDir, run, crashed, readTodos, findLine } = require('./_cli');

const ERROR_WORDS = /not found|invalid|no todo|does not exist|doesn't exist|unknown|missing|usage|required|provide|error|must/i;

function assertRejected(dir, args) {
  const before = JSON.stringify(readTodos(dir));
  const result = run(dir, ...args);
  assert.ok(!crashed(result), `crashed: ${result.err}`);
  assert.ok(result.code !== 0 || ERROR_WORDS.test(result.all), `no error reported: ${result.all}`);
  assert.equal(JSON.stringify(readTodos(dir)), before, 'the store changed');
}

test('[followup] edit replaces the text and keeps everything else', () => {
  const dir = freshDir();
  run(dir, 'add', 'old text');
  const before = readTodos(dir)[0];
  run(dir, 'complete', String(before.id));
  const result = run(dir, 'edit', String(before.id), 'new text');
  assert.equal(result.code, 0, result.all);
  const after = readTodos(dir)[0];
  assert.equal(after.text, 'new text');
  assert.equal(after.id, before.id);
  assert.equal(after.completed, true);
  assert.equal(after.createdAt, before.createdAt);
  assert.ok(run(dir, 'list').out.includes('new text'));
});

test('[followup] edit with an unknown id is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['edit', '99', 'text']);
});

test('[followup] edit without text is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  const { id } = readTodos(dir)[0];
  assertRejected(dir, ['edit', String(id)]);
  assertRejected(dir, ['edit', String(id), '']);
});

test('[followup] edit without an id is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['edit']);
});

test('[followup] list --pending shows only incomplete todos', () => {
  const dir = freshDir();
  run(dir, 'add', 'finished task');
  run(dir, 'add', 'open task');
  run(dir, 'complete', String(readTodos(dir)[0].id));
  const result = run(dir, 'list', '--pending');
  assert.equal(result.code, 0, result.all);
  assert.ok(!result.out.includes('finished task'), result.out);
  assert.ok((findLine(result.out, 'open task') || '').includes('[ ]'), result.out);
});

test('[followup] plain list still shows every todo', () => {
  const dir = freshDir();
  run(dir, 'add', 'finished task');
  run(dir, 'add', 'open task');
  run(dir, 'complete', String(readTodos(dir)[0].id));
  const listing = run(dir, 'list').out;
  assert.match(findLine(listing, 'finished task') || '', /\[x\]/i);
  assert.ok((findLine(listing, 'open task') || '').includes('[ ]'));
});
