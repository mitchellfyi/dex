const test = require('node:test');
const assert = require('node:assert');
const { paginate } = require('../src/pagination');

test('paginates an exact multiple', () => {
  const items = Array.from({ length: 20 }, (_, i) => ({ id: i + 1 }));
  const result = paginate(items, { page: 2, perPage: 10 });
  assert.equal(result.items.length, 10);
  assert.equal(result.items[0].id, 11);
  assert.equal(result.total, 20);
  assert.equal(result.lastPage, 2);
});

test('returns the first page by default', () => {
  const items = [{ id: 1 }, { id: 2 }, { id: 3 }];
  const result = paginate(items, { perPage: 2 });
  assert.equal(result.page, 1);
  assert.equal(result.items.length, 2);
});

test('sorts by the requested key', () => {
  const items = [{ id: 3 }, { id: 1 }, { id: 2 }];
  const result = paginate(items, { sortBy: 'id', perPage: 10 });
  assert.deepEqual(result.items.map((x) => x.id), [1, 2, 3]);
});

test('handles null options', () => {
  const items = [{ id: 1 }];
  const result = paginate(items, null);
  assert.equal(result.items.length, 1);
});
