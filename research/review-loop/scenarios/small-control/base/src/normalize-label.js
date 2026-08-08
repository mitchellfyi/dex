'use strict';

function normalizeLabel(value) {
  if (typeof value !== 'string') {
    throw new TypeError('label must be a string');
  }

  return value.trim().toLowerCase();
}

module.exports = { normalizeLabel };
