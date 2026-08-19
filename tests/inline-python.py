#!/usr/bin/env python3
"""Syntax-check the Python that lives inside shell heredocs.

`tests/check.sh` compiles `hooks/*.py` and `scripts/*.py`, but most of Dex's
Python is not in those files: around eighty programs are embedded in shell as
`python3 - <<'PY' … PY`. Nothing looked at those until run time, so a typo in
one shipped as a working script that failed the moment a lifecycle reached it —
and several of them run inside hooks, where the failure surfaces as a guard or
a phase silently degrading rather than an error anyone reads.

Only heredocs whose delimiter is quoted are checked. An unquoted delimiter
means the shell expands `$vars` in the body first, so what is on disk is a
template, not a program, and it may legitimately not parse on its own.

Usage: python3 tests/inline-python.py [--list]
"""

from __future__ import annotations

import ast
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# `python3 [flags] [-] [args] <<'TAG' [redirections]` … a line that is exactly
# TAG. Redirections after the delimiter are common (`<<'PY' 2>/dev/null`), so
# the rest of the opening line is skipped rather than required to end there.
# The delimiter must be quoted; see the module docstring.
HEREDOC = re.compile(
    r"""python3?\b[^\n<]*<<-?(?P<quote>['"])(?P<tag>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)[^\n]*\n"""
    r"""(?P<body>.*?)\n[ \t]*(?P=tag)$""",
    re.S | re.M,
)


def tracked_shell_files() -> list[pathlib.Path]:
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "*.sh", "dx.sh"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    # research/ is a scratch harness, not shipped runtime.
    return [ROOT / p for p in listing if not p.startswith("research/")]


def blocks(path: pathlib.Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in HEREDOC.finditer(text):
        line = text[: match.start("body")].count("\n") + 1
        yield line, match.group("tag"), match.group("body")


def main() -> int:
    listing = "--list" in sys.argv
    checked = 0
    failures = 0

    for path in tracked_shell_files():
        if not path.is_file():
            continue
        for line, tag, body in blocks(path):
            checked += 1
            rel = path.relative_to(ROOT)
            if listing:
                print(f"{rel}:{line}: <<{tag} ({body.count(chr(10)) + 1} lines)")
                continue
            try:
                # The heredoc body starts at column 0 of its own program, but
                # feature_version keeps this honest about what Dex targets.
                ast.parse(body, filename=f"{rel}:{line} <<{tag}")
            except SyntaxError as error:
                failures += 1
                print(
                    f"{rel}:{line + (error.lineno or 1) - 1}: "
                    f"inline python in <<{tag} does not parse: {error.msg}",
                    file=sys.stderr,
                )

    if listing:
        return 0
    if failures:
        print(
            f"\n{failures} embedded Python block(s) failed to parse. "
            f"These never reach py_compile, so nothing else catches them.",
            file=sys.stderr,
        )
        return 1
    print(f"inline python: {checked} embedded block(s) parse")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
