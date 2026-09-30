#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const STORE = path.join(process.cwd(), 'todos.json');

function load() {
  if (!fs.existsSync(STORE)) {
    return { nextId: 1, todos: [] };
  }
  const data = JSON.parse(fs.readFileSync(STORE, 'utf8'));
  if (!data || !Array.isArray(data.todos) || !Number.isInteger(data.nextId)) {
    throw new Error('todos.json is not a valid todo store');
  }
  return data;
}

function save(store) {
  const tmp = `${STORE}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(store, null, 2)}\n`);
  fs.renameSync(tmp, STORE);
}

function parseId(raw) {
  if (!/^\d+$/.test(raw || '')) {
    throw new Error(`invalid id: ${raw === undefined ? '(missing)' : raw}`);
  }
  return Number(raw);
}

function find(store, id) {
  const todo = store.todos.find(t => t.id === id);
  if (!todo) {
    throw new Error(`todo ${id} not found`);
  }
  return todo;
}

function format(todo) {
  return `${todo.id}. [${todo.completed ? 'x' : ' '}] ${todo.text}`;
}

const commands = {
  add(store, text) {
    if (!text || !text.trim()) {
      throw new Error('usage: add "<text>"');
    }
    const todo = { id: store.nextId, text, completed: false, createdAt: new Date().toISOString() };
    store.nextId += 1;
    store.todos.push(todo);
    save(store);
    return `Added ${format(todo)}`;
  },
  list(store, flag) {
    const todos = flag === '--pending' ? store.todos.filter(t => !t.completed) : store.todos;
    if (todos.length === 0) {
      return 'No todos.';
    }
    return todos.map(format).join('\n');
  },
  edit(store, rawId, text) {
    const todo = find(store, parseId(rawId));
    if (!text || !text.trim()) {
      throw new Error('usage: edit <id> "<text>"');
    }
    todo.text = text;
    save(store);
    return `Edited ${format(todo)}`;
  },
  complete(store, rawId) {
    const todo = find(store, parseId(rawId));
    todo.completed = true;
    save(store);
    return `Completed ${format(todo)}`;
  },
  delete(store, rawId) {
    const id = parseId(rawId);
    find(store, id);
    store.todos = store.todos.filter(t => t.id !== id);
    save(store);
    return `Deleted todo ${id}`;
  }
};

function main(argv) {
  const [name, ...args] = argv;
  const command = commands[name];
  if (!command) {
    throw new Error(`usage: node index.js <${Object.keys(commands).join('|')}> [args]`);
  }
  return command(load(), ...args);
}

if (require.main === module) {
  try {
    console.log(main(process.argv.slice(2)));
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exitCode = 1;
  }
}

module.exports = { main };
