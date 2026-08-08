#!/usr/bin/env python3
"""Verify the producer output can be consumed without manual adaptation."""

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
const { summarizeOrder } = require('./src/order-summary');
const { formatReceipt } = require('./src/receipt');

const summary = summarizeOrder([{ price: 5 }, { price: 7 }]);
assert.equal(summary.grandTotal, 12);
assert.equal(formatReceipt(summary, 'usd'), 'USD 12.00');
assert.equal(formatReceipt({ total: 3 }, 'EUR'), 'EUR 3.00');
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
