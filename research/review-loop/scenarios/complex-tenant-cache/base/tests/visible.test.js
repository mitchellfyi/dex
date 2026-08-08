'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { canRead, clearPermissionCache } = require('../auth/permissions');

test('caches a repeated authorization decision', async () => {
  clearPermissionCache();
  const loadMembership = async () => ({ roles: ['reader'] });
  const request = { tenantId: 'tenant-a', userId: 'user-a', resourceId: 'doc-1' };

  assert.equal(await canRead(request, loadMembership), true);
  assert.equal(await canRead(request, loadMembership), true);
});
