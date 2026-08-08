'use strict';

async function canRead(request, loadMembership) {
  const membership = await loadMembership(request.tenantId, request.userId);
  return membership.roles.includes('reader');
}

function clearPermissionCache() {}

module.exports = { canRead, clearPermissionCache };
