#!/usr/bin/env python3
"""Reject `[[ … ]]` used as a test assertion with no consequence.

bash 3.2 is `/bin/bash` on macOS, and what the macOS CI leg runs. It does not
apply `set -e` to a failing `[[ … ]]` used as a statement — `false` and every
ordinary command trip errexit there, that keyword does not. So a test written

    [[ "$(dx_default_branch "$repo")" == "master" ]]

passes on that leg no matter what it claims. 365 assertions across this suite
were in that shape; one was edited to assert `"master" == "THIS-IS-WRONG"` and
the test still printed "passed" and exited 0.

The fix at each site is to give the test an explicit consequence:

    [[ … ]] || assert_at $LINENO     # an assertion (see tests/helpers.sh)
    [[ … ]] || return 1              # a predicate the caller checks
    [[ … ]] || fail "what went wrong"

This only scans `tests/`. Under `lib/`, `hooks/`, and `bin/` the bare form is
the normal way to write a predicate — the status is the function's return
value, which is unaffected — and all 48 uses there are exactly that.

Usage: python3 tests/bare-assertions.py [--list]
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# A `[[ … ]]` that is the whole statement: nothing before it on the line, and
# no `&&`, `||`, `;`, or line continuation after it.
BARE = re.compile(r"^\s*\[\[ .* \]\]\s*$")
# `if`/`while`/`until` conditions and `&&`/`||` chains never match the above,
# so no exclusion list is needed for them.


def tracked_tests() -> list[pathlib.Path]:
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "tests/*.sh"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [ROOT / path for path in listing]


def findings(path: pathlib.Path) -> list[tuple[int, str]]:
    found = []
    in_heredoc: str | None = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        # Heredoc bodies are another language's source, or shell for a
        # different shell; `[[ … ]]` in there is not this file's assertion.
        if in_heredoc is not None:
            if line.strip() == in_heredoc:
                in_heredoc = None
            continue
        opener = re.search(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?\s*$", line)
        if opener and "<<<" not in line:
            in_heredoc = opener.group(1)
            continue
        if BARE.match(line):
            found.append((number, line.strip()))
    return found


def main() -> int:
    listing = "--list" in sys.argv
    total = 0

    for path in tracked_tests():
        if not path.is_file():
            continue
        for number, text in findings(path):
            rel = path.relative_to(ROOT)
            print(f"{rel}:{number}: bare `[[ … ]]` has no effect on bash 3.2: {text}")
            total += 1

    if listing:
        return 0
    if total:
        print(
            f"\n{total} assertion(s) that bash 3.2 ignores. Add a consequence:\n"
            f"  `|| assert_at $LINENO` for an assertion, `|| return 1` for a\n"
            f"  predicate, `|| fail \"…\"` to say what went wrong.",
            file=sys.stderr,
        )
        return 1
    print("bare-assertions: every test assertion has a consequence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
