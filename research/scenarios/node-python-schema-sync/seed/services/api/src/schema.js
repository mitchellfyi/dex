const fs = require('node:fs');
const path = require('node:path');

const schemaPath = path.resolve(__dirname, '../../../schemas/event.json');

function loadEventSchema() {
  return JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
}

function applyDefaults(event, schema = loadEventSchema()) {
  const copy = { ...event };
  for (const [key, definition] of Object.entries(schema.properties || {})) {
    if (copy[key] === undefined && Object.prototype.hasOwnProperty.call(definition, 'default')) {
      copy[key] = definition.default;
    }
  }
  return copy;
}

function validateEvent(event, schema = loadEventSchema()) {
  const errors = [];
  const candidate = applyDefaults(event, schema);

  for (const field of schema.required || []) {
    if (candidate[field] === undefined || candidate[field] === null || candidate[field] === '') {
      errors.push(`${field} is required`);
    }
  }

  for (const [key, value] of Object.entries(candidate)) {
    const definition = schema.properties[key];
    if (!definition) {
      errors.push(`${key} is not allowed`);
      continue;
    }
    if (definition.type === 'string' && typeof value !== 'string') {
      errors.push(`${key} must be a string`);
    }
    if (definition.type === 'object' && (typeof value !== 'object' || value === null || Array.isArray(value))) {
      errors.push(`${key} must be an object`);
    }
    if (definition.enum && !definition.enum.includes(value)) {
      errors.push(`${key} must be one of ${definition.enum.join(', ')}`);
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    event: candidate
  };
}

module.exports = {
  schemaPath,
  loadEventSchema,
  applyDefaults,
  validateEvent
};
