'use strict';

const fs = require('node:fs');

function releaseLock(lockPath, _ownerToken) {
  try {
    fs.unlinkSync(lockPath);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') {
      return false;
    }
    throw error;
  }
}

module.exports = { releaseLock };
