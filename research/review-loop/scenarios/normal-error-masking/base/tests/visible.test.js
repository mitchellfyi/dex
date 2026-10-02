'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { listCatalog } = require('../src/catalog-service');

test('returns items from a successful catalog request', async () => {
  const transport = {
    async get() {
      return { items: [{ id: 'item-1' }] };
    },
  };

  assert.deepEqual(await listCatalog(transport), [{ id: 'item-1' }]);
});
