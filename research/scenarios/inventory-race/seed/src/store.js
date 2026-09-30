'use strict';

// In-memory key-value store with the latency profile of the Redis cluster
// used in production: every call yields to the event loop before it reads or
// writes, so concurrent callers interleave the way they do against the real
// store. Values are copied on the way in and out.
class Store {
  constructor() {
    this.data = new Map();
  }

  async get(key) {
    await tick();
    const value = this.data.get(key);
    return value === undefined ? undefined : structuredClone(value);
  }

  async set(key, value) {
    await tick();
    this.data.set(key, structuredClone(value));
  }

  async keys(prefix) {
    await tick();
    return [...this.data.keys()].filter(key => key.startsWith(prefix));
  }
}

function tick() {
  return new Promise(resolve => setImmediate(resolve));
}

module.exports = { Store };
