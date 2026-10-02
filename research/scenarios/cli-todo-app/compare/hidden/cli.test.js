'use strict';
// Hidden tests for cli-todo-app. The agent never sees these.
//
// [spec] is what the prompt states. [robust] is what a careful implementation
// of the same prompt would also get right. An error may be reported either by
// a non-zero exit or by a message; what fails is a crash or a changed store.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { freshDir, run, crashed, readTodos, findLine } = require('./_cli');

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const ERROR_WORDS = /not found|invalid|no todo|does not exist|doesn't exist|unknown|missing|usage|required|provide|error|must/i;

function assertRejected(dir, args) {
  const before = JSON.stringify(readTodos(dir));
  const result = run(dir, ...args);
  assert.ok(!crashed(result), `crashed: ${result.err}`);
  assert.ok(result.code !== 0 || ERROR_WORDS.test(result.all), `no error reported: ${result.all}`);
  assert.equal(JSON.stringify(readTodos(dir)), before, 'the store changed');
}

test('[spec] add stores a todo with id, text, completed and createdAt', () => {
  const dir = freshDir();
  const result = run(dir, 'add', 'Buy groceries');
  assert.equal(result.code, 0, result.all);
  const todos = readTodos(dir);
  assert.equal(todos.length, 1);
  const [todo] = todos;
  assert.ok(Number.isInteger(todo.id));
  assert.equal(todo.text, 'Buy groceries');
  assert.equal(todo.completed, false);
  assert.match(String(todo.createdAt), ISO);
});

test('[spec] ids auto-increment', () => {
  const dir = freshDir();
  run(dir, 'add', 'first');
  run(dir, 'add', 'second');
  const todos = readTodos(dir);
  assert.equal(todos.length, 2);
  assert.equal(todos[1].id, todos[0].id + 1);
});

test('[spec] list shows id, status and text', () => {
  const dir = freshDir();
  run(dir, 'add', 'Buy groceries');
  const id = readTodos(dir)[0].id;
  const result = run(dir, 'list');
  assert.equal(result.code, 0, result.all);
  const line = findLine(result.out, 'Buy groceries');
  assert.ok(line, `todo missing from list: ${result.out}`);
  assert.ok(line.includes('[ ]'), line);
  assert.match(line, new RegExp(`(^|\\D)${id}(\\D|$)`));
});

test('[spec] complete marks a todo done', () => {
  const dir = freshDir();
  run(dir, 'add', 'one');
  run(dir, 'add', 'two');
  const [first] = readTodos(dir);
  assert.equal(run(dir, 'complete', String(first.id)).code, 0);
  const todos = readTodos(dir);
  assert.equal(todos[0].completed, true);
  assert.equal(todos[1].completed, false);
  const listing = run(dir, 'list').out;
  assert.match(findLine(listing, 'one') || '', /\[x\]/i);
  assert.ok((findLine(listing, 'two') || '').includes('[ ]'));
});

test('[spec] delete removes a todo', () => {
  const dir = freshDir();
  run(dir, 'add', 'keep me');
  run(dir, 'add', 'drop me');
  const drop = readTodos(dir)[1];
  assert.equal(run(dir, 'delete', String(drop.id)).code, 0);
  const todos = readTodos(dir);
  assert.deepEqual(todos.map(t => t.text), ['keep me']);
  assert.ok(!run(dir, 'list').out.includes('drop me'));
});

test('[spec] listing an empty store succeeds', () => {
  const dir = freshDir();
  const result = run(dir, 'list');
  assert.equal(result.code, 0, result.all);
  assert.ok(!crashed(result));
});

test('[spec] add without text is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['add']);
});

test('[spec] complete with an unknown id is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['complete', '99']);
});

test('[spec] delete with an unknown id is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['delete', '99']);
});

test('[spec] a non-numeric id is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['complete', 'abc']);
  assertRejected(dir, ['delete', 'abc']);
});

test('[spec] complete and delete without an id are rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['complete']);
  assertRejected(dir, ['delete']);
});

test('[robust] ids are not reused after deleting the newest todo', () => {
  const dir = freshDir();
  run(dir, 'add', 'a');
  run(dir, 'add', 'b');
  const b = readTodos(dir)[1];
  run(dir, 'delete', String(b.id));
  run(dir, 'add', 'c');
  const c = readTodos(dir).find(t => t.text === 'c');
  assert.ok(c.id > b.id, `id ${c.id} reused`);
});

test('[robust] a corrupt todos.json is reported without a crash', () => {
  const dir = freshDir();
  fs.writeFileSync(path.join(dir, 'todos.json'), '{not json');
  const result = run(dir, 'list');
  assert.ok(!crashed(result), result.err);
});

test('[robust] unicode and quotes survive a round trip', () => {
  const dir = freshDir();
  const text = 'Café "déjà vu" ✓';
  assert.equal(run(dir, 'add', text).code, 0);
  assert.equal(readTodos(dir)[0].text, text);
  assert.ok(run(dir, 'list').out.includes(text));
});

test('[robust] an unknown command is reported without a crash', () => {
  const dir = freshDir();
  const result = run(dir, 'frobnicate');
  assert.ok(!crashed(result), result.err);
  assert.ok(result.code !== 0 || ERROR_WORDS.test(result.all), result.all);
});

test('[robust] whitespace-only text is rejected', () => {
  const dir = freshDir();
  run(dir, 'add', 'existing');
  assertRejected(dir, ['add', '   ']);
});

test('[robust] completing a todo twice is harmless', () => {
  const dir = freshDir();
  run(dir, 'add', 'once');
  const { id } = readTodos(dir)[0];
  run(dir, 'complete', String(id));
  const again = run(dir, 'complete', String(id));
  assert.ok(!crashed(again), again.err);
  assert.equal(readTodos(dir)[0].completed, true);
});
