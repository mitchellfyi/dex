'use strict';

function effectiveLimit(config, defaultLimit) {
  return config.limit === undefined ? defaultLimit : config.limit;
}

module.exports = { effectiveLimit };
