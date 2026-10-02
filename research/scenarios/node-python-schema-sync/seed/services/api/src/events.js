const fs = require('node:fs');
const path = require('node:path');
const { validateEvent } = require('./schema');

const defaultLogPath = path.resolve(__dirname, '../events.log');

function createEvent(input, options = {}) {
  const validation = validateEvent(input);
  if (!validation.valid) {
    const error = new Error(validation.errors.join('; '));
    error.statusCode = 400;
    throw error;
  }

  const event = validation.event;
  if (options.emit !== false) {
    const logPath = options.logPath || defaultLogPath;
    fs.appendFileSync(logPath, `${JSON.stringify(event)}\n`);
  }
  return event;
}

function handleCreateEvent(req, options = {}) {
  return {
    statusCode: 202,
    body: createEvent(req.body || {}, options)
  };
}

module.exports = {
  createEvent,
  handleCreateEvent
};
