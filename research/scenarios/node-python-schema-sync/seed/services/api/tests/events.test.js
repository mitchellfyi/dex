const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createEvent, handleCreateEvent } = require('../src/events');
const { loadEventSchema, validateEvent } = require('../src/schema');

function event(overrides = {}) {
  return {
    event_id: 'evt_1',
    user_id: 'user_1',
    type: 'user.created',
    payload: { plan: 'pro' },
    occurred_at: '2026-01-01T00:00:00.000Z',
    ...overrides
  };
}

test('loads the shared schema from the workspace schema directory', () => {
  const schema = loadEventSchema();

  assert.equal(schema.title, 'Event');
  assert.equal(schema.properties.event_id.type, 'string');
});

test('validates and emits a valid event', () => {
  const logPath = path.join(os.tmpdir(), `events-${Date.now()}.log`);
  const created = createEvent(event(), { logPath });

  assert.equal(created.event_id, 'evt_1');
  assert.match(fs.readFileSync(logPath, 'utf8'), /evt_1/);
});

test('rejects unknown properties', () => {
  const validation = validateEvent(event({ unexpected: true }));

  assert.equal(validation.valid, false);
  assert.match(validation.errors.join(' '), /unexpected is not allowed/);
});

test('handleCreateEvent returns accepted response', () => {
  const response = handleCreateEvent({ body: event({ event_id: 'evt_2' }) }, { emit: false });

  assert.equal(response.statusCode, 202);
  assert.equal(response.body.event_id, 'evt_2');
});
