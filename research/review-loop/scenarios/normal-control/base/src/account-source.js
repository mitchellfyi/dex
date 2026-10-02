'use strict';

function createAccountSource(records) {
  return {
    findAccount(id) {
      const record = records.find((entry) => entry.id === id);
      return record ? { name: record.name } : null;
    },
  };
}

module.exports = { createAccountSource };
