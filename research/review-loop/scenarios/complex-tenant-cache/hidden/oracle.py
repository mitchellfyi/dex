#!/usr/bin/env python3
"""Verify cached authorization decisions remain principal-scoped."""

from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: oracle.py WORKSPACE", file=sys.stderr)
        return 2

    workspace = Path(sys.argv[1]).resolve()
    script = r"""
const assert = require('node:assert/strict');
const { canRead, clearPermissionCache } = require('./auth/permissions');

const memberships = new Map([
  [JSON.stringify(['tenant-a', 'user-a']), { roles: ['reader'] }],
  [JSON.stringify(['tenant-b', 'user-b']), { roles: [] }],
  [JSON.stringify(['tenant:a', 'user-c']), { roles: ['reader'] }],
  [JSON.stringify(['tenant', 'a:user-c']), { roles: [] }],
]);
const loadMembership = async (tenantId, userId) => (
  memberships.get(JSON.stringify([tenantId, userId]))
);

(async () => {
  clearPermissionCache();
  assert.equal(await canRead({
    tenantId: 'tenant-a', userId: 'user-a', resourceId: 'shared-doc',
  }, loadMembership), true);
  assert.equal(await canRead({
    tenantId: 'tenant-b', userId: 'user-b', resourceId: 'shared-doc',
  }, loadMembership), false);

  assert.equal(await canRead({
    tenantId: 'tenant:a', userId: 'user-c', resourceId: 'report',
  }, loadMembership), true);
  assert.equal(await canRead({
    tenantId: 'tenant', userId: 'a:user-c', resourceId: 'report',
  }, loadMembership), false);
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
"""
    result = subprocess.run(
        ["node", "-e", script],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr or result.stdout)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
