'use strict';

const fs = require('node:fs');

function releaseLock(lockPath, ownerToken) {
  let metadata;
  try {
    metadata = fs.lstatSync(lockPath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return false;
    }
    throw error;
  }

  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    return false;
  }
  if (fs.readFileSync(lockPath, 'utf8') !== ownerToken) {
    return false;
  }

  fs.unlinkSync(lockPath);
  return true;
}

module.exports = { releaseLock };
