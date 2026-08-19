#!/usr/bin/env python3
"""A function that answers a question must not fail when the answer is "none".

`[[ … ]] && printf …` as the last statement of a function makes the test's
result the function's exit status. For a predicate that is the point. For a
function that prints a value it is an accident, and an expensive one: every
caller writes `value=$(fn …)`, which under `set -e` ends the caller outright.

That is how `dx control` came to exit 1 without printing a word — including
`dx control status`, whose entire job is to report that no lifecycle is
running. Nothing else catches it, because the shape is correct shell and the
suite exercises the path where the answer is non-empty.

The rule only looks at functions that print, so predicates ending in a test are
untouched. Give a value-producing function an explicit `return 0`.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FUNCTION_RE = re.compile(r'^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{\s*$')
TRAILING_AND_RE = re.compile(r'^\[\[ .* \]\] +&& ')
PRODUCES_RE = re.compile(r'\b(printf|echo)\b')


def tracked_shell_files():
    listed = subprocess.run(
        ['git', 'ls-files', '-z'],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split('\0')
    return sorted(
        name for name in listed
        if name and name.endswith('.sh') and not name.startswith('tests/')
        and (ROOT / name).is_file()
    )


def offenders(name):
    lines = (ROOT / name).read_text(encoding='utf-8', errors='replace').splitlines()
    start = None
    body = []
    for index, line in enumerate(lines):
        if start is None:
            if FUNCTION_RE.match(line):
                start, body = index, []
            continue
        if line == '}':
            statements = [
                entry for entry in body
                if entry.strip() and not entry.strip().startswith('#')
            ]
            if statements and PRODUCES_RE.search('\n'.join(body)):
                if TRAILING_AND_RE.match(statements[-1].strip()):
                    yield start + 1, lines[start].strip().rstrip('() {')
            start = None
        else:
            body.append(line)


def main():
    failures = []
    for name in tracked_shell_files():
        for number, function in offenders(name):
            failures.append(
                f'{name}:{number}: {function} prints a value but ends in '
                f'`[[ … ]] && …`, so it fails when there is nothing to print; '
                f'add an explicit `return 0`'
            )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print('accidental exit status: no value-producing function ends in a bare `&&` list')
    return 0


if __name__ == '__main__':
    sys.exit(main())
