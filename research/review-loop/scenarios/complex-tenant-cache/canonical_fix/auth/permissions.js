'use strict';

const permissionCache = new Map();

async function canRead(request, loadMembership) {
  const cacheKey = JSON.stringify([
    request.tenantId,
    request.userId,
    request.resourceId,
  ]);
  if (permissionCache.has(cacheKey)) {
    return permissionCache.get(cacheKey);
  }

  const membership = await loadMembership(request.tenantId, request.userId);
  const allowed = membership.roles.includes('reader');
  permissionCache.set(cacheKey, allowed);
  return allowed;
}

function clearPermissionCache() {
  permissionCache.clear();
}

module.exports = { canRead, clearPermissionCache };
