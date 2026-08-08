#!/usr/bin/env python3
"""Verify a non-owner cannot release or redirect a hook lock."""

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
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { releaseLock } = require('./hooks/release-lock');

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-lock-hidden-'));
try {
  const lockPath = path.join(directory, 'worker.lock');
  fs.writeFileSync(lockPath, 'owner-a');
  assert.equal(releaseLock(lockPath, 'owner-b'), false);
  assert.equal(fs.readFileSync(lockPath, 'utf8'), 'owner-a');

  const targetPath = path.join(directory, 'target.lock');
  const linkPath = path.join(directory, 'linked.lock');
  fs.writeFileSync(targetPath, 'owner-b');
  fs.symlinkSync(targetPath, linkPath);
  assert.equal(releaseLock(linkPath, 'owner-b'), false);
  assert.equal(fs.existsSync(targetPath), true);
  assert.equal(fs.lstatSync(linkPath).isSymbolicLink(), true);
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
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
