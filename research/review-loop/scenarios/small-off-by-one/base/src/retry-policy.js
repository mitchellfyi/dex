'use strict';

function canAttempt(attemptNumber, maxAttempts) {
  return attemptNumber >= 1 && attemptNumber <= maxAttempts;
}

module.exports = { canAttempt };
