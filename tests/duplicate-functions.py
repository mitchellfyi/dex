#!/usr/bin/env python3
"""No shipped shell file may define the same function name twice.

The second definition wins, silently, and the first one's callers get it. In a
file the size of bin/maintain.sh nobody is holding all the names in their head,
so the collision looks like the function simply misbehaving: I added a helper
here whose name was already taken 120 lines further down, and the symptom was a
branch name being rejected as a run id.

Tests are exempt. Redefining a stub between phases — a different __dx_claude
for each stage of a lifecycle — is how several of them work, and there the
later definition winning is the point.
"""

import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FUNCTION = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\) *\{")


def shipped_shell_files():
    listed = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split("\0")
    return sorted(
        name for name in listed
        if name and (name.endswith(".sh") or name == "dx.sh")
        and not name.startswith("tests/")
        and (ROOT / name).is_file()
    )


def main():
    failures = []
    for name in shipped_shell_files():
        seen = defaultdict(list)
        text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), start=1):
            match = FUNCTION.match(line)
            if match:
                seen[match.group(1)].append(number)
        for function, numbers in sorted(seen.items()):
            if len(numbers) > 1:
                places = ", ".join(str(n) for n in numbers)
                failures.append(
                    f"{name}:{numbers[-1]}: {function} is defined more than once "
                    f"(lines {places}); the last one silently wins"
                )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("duplicate functions: no shipped shell file defines a name twice")
    return 0


if __name__ == "__main__":
    sys.exit(main())
