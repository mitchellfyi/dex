'use strict';

function effectiveLimit(config, defaultLimit) {
  return config.limit || defaultLimit;
}

module.exports = { effectiveLimit };
